import Foundation
import Synchronization
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// A small newline-framed JSON Unix socket. Kernel peer credentials are captured before a byte
/// supplied by the caller is decoded.
final class LocalJSONSocket<Request: Decodable & Sendable, Answer: Encodable & Sendable>: @unchecked Sendable {
    typealias Handler = @Sendable (Request, LocalSocket.Peer?) async -> Answer?

    private let descriptor: Int32
    private let path: String
    private let handler: Handler
    private let closing = Mutex(false)

    init(path: String, group: String? = nil, handler: @escaping Handler) throws {
        self.path = path
        self.handler = handler
        unlink(path)
        #if canImport(Glibc)
        let stream = Int32(SOCK_STREAM.rawValue)
        #else
        let stream = SOCK_STREAM
        #endif
        descriptor = socket(AF_UNIX, stream, 0)
        guard descriptor >= 0 else { throw LocalSocket.Failure.socket(errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let limit = MemoryLayout.size(ofValue: address.sun_path) - 1
        guard path.utf8.count <= limit else { throw LocalSocket.Failure.pathTooLong(limit) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in path.utf8.enumerated() { raw[index] = byte }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, size) }
        }
        guard bound == 0 else { Foundation.close(descriptor); throw LocalSocket.Failure.bind(errno) }
        if let group, let entry = group.withCString({ getgrnam($0) }) {
            chown(path, getuid(), entry.pointee.gr_gid)
        }
        chmod(path, 0o660)
        guard listen(descriptor, 32) == 0 else {
            Foundation.close(descriptor)
            throw LocalSocket.Failure.listen(errno)
        }
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "bloom-local-json"
        thread.start()
    }

    deinit { close() }

    func close() {
        let shouldClose = closing.withLock { closing -> Bool in
            guard !closing else { return false }
            closing = true
            return true
        }
        guard shouldClose else { return }
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
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let peer = LocalSocket.peer(of: connection)
        guard let body = LocalSocket.read(connection),
              let request = try? JSONDecoder().decode(Request.self, from: body) else { return }
        let done = DispatchSemaphore(value: 0)
        let result = Mutex<Answer?>(nil)
        Task {
            let answer = await handler(request, peer)
            result.withLock { $0 = answer }
            done.signal()
        }
        done.wait()
        guard let answer = result.withLock({ $0 }), var encoded = try? JSONEncoder().encode(answer) else { return }
        encoded.append(0x0A)
        encoded.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(connection, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard count > 0 else { return }
                offset += count
            }
        }
    }
}

typealias PersonBoundCredentialSocket = LocalJSONSocket<PersonBoundCredentialRequest, PersonBoundCredentialAnswer>
