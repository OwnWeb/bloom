import BloomCore
import Foundation
import Synchronization
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// The door a process on this machine asks for a GitHub token through, where the kernel says who is
/// knocking.
///
/// **Why a unix socket and not the loopback route it replaces.** The loopback route proved nothing
/// about its caller: it took a shared secret every process could read, and a chat id the caller
/// stated. The fix for that (M1 in the security review of 19 September 2026) read the caller's
/// ancestry out of `/proc`, found by matching the connection's port to a socket inode and that inode
/// to a file descriptor. That works only while everything runs as one user: `/proc/<pid>/fd` and
/// `/proc/<pid>/environ` are readable by that process's own user alone, and the sandbox exists
/// precisely so agents run as another. A unix socket answers the same question without asking the
/// filesystem: `SO_PEERCRED` is filled in by the kernel from the peer at connect time, and nothing
/// the caller sends can change it.
///
/// So the pid is the kernel's word, and what that pid means is `SpawnedProcesses`, which holds the
/// pids this Runner started itself. The shared secret is gone: reaching the socket at all is the
/// permission, and it is granted by group on the socket file.
///
/// **A thread of its own, on purpose.** `accept` and `read` here are blocking calls, and a blocking
/// call on a cooperative thread starves Swift's pool; credential requests are rare (a push, a fetch)
/// and short, so one thread that blocks is simpler than a non-blocking loop and cannot misbehave in
/// a way that matters.
final class LocalCredentialSocket: @unchecked Sendable {
    /// Who the kernel says is on the other end.
    struct Peer: Sendable, Hashable {
        var pid: Int32
        var uid: UInt32
    }

    /// **`Peer` is optional, and nil means "the kernel would not say".** That is a Mac, where there
    /// is no `SO_PEERCRED`, and it has to be answerable rather than fatal so the transport can be
    /// tested; `LocalCredentialAuthority` turns a nil peer into a read-only token.
    typealias Answering = @Sendable (GitCredentialRoute.Asked, Peer?) async -> GitCredentialRoute.Answer?

    private let descriptor: Int32
    private let path: String
    private let answer: Answering
    private let closing = Mutex(false)

    /// Listens on `path`, owned by this user and readable and writable by `group` alone, so the
    /// sandbox user can ask and nothing else on the machine can.
    init(path: String, group: String? = nil, answer: @escaping Answering) throws {
        self.path = path
        self.answer = answer
        unlink(path)
        #if canImport(Glibc)
        let stream = Int32(SOCK_STREAM.rawValue)
        #else
        let stream = SOCK_STREAM
        #endif
        descriptor = socket(AF_UNIX, stream, 0)
        guard descriptor >= 0 else { throw Failure.socket(errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let limit = MemoryLayout.size(ofValue: address.sun_path) - 1
        guard path.utf8.count <= limit else { throw Failure.pathTooLong(limit) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in path.utf8.enumerated() { raw[index] = byte }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, size) }
        }
        guard bound == 0 else { Foundation.close(descriptor); throw Failure.bind(errno) }
        // The group is the permission. 0660 and not 0666, so a process outside the group cannot
        // even connect, and the answer to "may I have a token" starts from that rather than a secret.
        if let group, let entry = group.withCString({ getgrnam($0) }) {
            chown(path, getuid(), entry.pointee.gr_gid)
        }
        chmod(path, 0o660)
        guard listen(descriptor, 16) == 0 else { Foundation.close(descriptor); throw Failure.listen(errno) }
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "bloom-credentials"
        thread.start()
    }

    func close() {
        closing.withLock { $0 = true }
        shutdown(descriptor, Int32(SHUT_RDWR))
        Foundation.close(descriptor)
        unlink(path)
    }

    private func acceptLoop() {
        while !closing.withLock({ $0 }) {
            let connection = accept(descriptor, nil, nil)
            guard connection >= 0 else {
                if errno == EINTR { continue }
                return
            }
            handle(connection)
            Foundation.close(connection)
        }
    }

    private func handle(_ connection: Int32) {
        // A caller that sends nothing must not hold the thread: five seconds is a cap on never.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let peer = Self.peer(of: connection)
        guard let request = Self.read(connection),
              let asked = try? JSONDecoder().decode(GitCredentialRoute.Asked.self, from: request) else { return }
        // The blocking thread waits here for the actor work the answer needs. Nothing else runs on
        // this thread, so there is nothing to starve.
        let done = DispatchSemaphore(value: 0)
        let box = Mutex<GitCredentialRoute.Answer?>(nil)
        let answering = answer
        Task {
            let answer = await answering(asked, peer)
            box.withLock { $0 = answer }
            done.signal()
        }
        done.wait()
        guard let answer = box.withLock({ $0 }), var body = try? JSONEncoder().encode(answer) else {
            _ = "{}\n".withCString { write(connection, $0, 2) }
            return
        }
        body.append(0x0A)
        body.withUnsafeBytes { raw in
            var written = 0
            while written < raw.count {
                let sent = write(connection, raw.baseAddress!.advanced(by: written), raw.count - written)
                guard sent > 0 else { return }
                written += sent
            }
        }
    }

    /// One line, up to 16 KiB, which is far more than a request that names a repository and a chat.
    static func read(_ connection: Int32) -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < 16 * 1_024 {
            let got = Foundation.read(connection, &byte, 1)
            guard got == 1 else { return data.isEmpty ? nil : data }
            if byte == 0x0A { return data }
            data.append(byte)
        }
        return data
    }

    /// The pid and uid the kernel recorded when the peer connected. Linux only; a Mac has no
    /// `SO_PEERCRED` and the machine is Linux, so elsewhere this answers nil and the caller refuses.
    static func peer(of connection: Int32) -> Peer? {
        #if canImport(Glibc)
        // **Three 32-bit fields, not `ucred`.** Swift's Glibc does not surface that struct (it is
        // behind `_GNU_SOURCE`), and its layout is fixed by the kernel's ABI: pid, uid, gid, each
        // 32 bits. Read as a buffer rather than named, because a named type nobody can import is a
        // build that fails on Linux and passes on a Mac, which is how this was found.
        var fields = [UInt32](repeating: 0, count: 3)
        var size = socklen_t(MemoryLayout<UInt32>.size * 3)
        let read = fields.withUnsafeMutableBytes { raw in
            getsockopt(connection, SOL_SOCKET, SO_PEERCRED, raw.baseAddress, &size)
        }
        guard read == 0, size >= 8 else { return nil }
        return Peer(pid: Int32(bitPattern: fields[0]), uid: fields[1])
        #else
        return nil
        #endif
    }

    enum Failure: Error, CustomStringConvertible {
        case socket(Int32)
        case bind(Int32)
        case listen(Int32)
        case pathTooLong(Int)

        var description: String {
            switch self {
            case .socket(let code): "the credential socket could not be made: \(String(cString: strerror(code)))"
            case .bind(let code): "the credential socket could not be bound: \(String(cString: strerror(code)))"
            case .listen(let code): "the credential socket could not listen: \(String(cString: strerror(code)))"
            case .pathTooLong(let limit): "a unix socket path is at most \(limit) characters"
            }
        }
    }
}
