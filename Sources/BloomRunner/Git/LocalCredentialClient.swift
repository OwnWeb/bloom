import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Asking the peer-authenticated local socket for one operation's credential.
///
/// Blocking on purpose, and short: this runs inside a one-shot process git started and waited for,
/// so there is nothing else for it to do, and a timeout keeps a machine whose Runner is restarting
/// from holding a `git push` open.
enum LocalCredentialClient {
    static let timeout = 30.0

    static func askV2(_ request: PersonBoundCredentialRequest, over path: String) -> PersonBoundCredentialAnswer? {
        exchange(request, over: path)
    }

    static func exchange<Request: Encodable, Answer: Decodable>(_ request: Request, over path: String) -> Answer? {
        #if canImport(Glibc)
        let stream = Int32(SOCK_STREAM.rawValue)
        #else
        let stream = SOCK_STREAM
        #endif
        let descriptor = socket(AF_UNIX, stream, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in path.utf8.enumerated() { raw[index] = byte }
        }
        var limit = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let joined = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, size) }
        }
        guard joined == 0, var body = try? JSONEncoder().encode(request) else { return nil }
        body.append(0x0A)
        let sent = body.withUnsafeBytes { raw -> Bool in
            var written = 0
            while written < raw.count {
                let count = write(descriptor, raw.baseAddress!.advanced(by: written), raw.count - written)
                guard count > 0 else { return false }
                written += count
            }
            return true
        }
        guard sent, let answered = LocalSocket.read(descriptor), !answered.isEmpty else { return nil }
        return try? JSONDecoder().decode(Answer.self, from: answered)
    }
}
