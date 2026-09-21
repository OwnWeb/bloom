import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Shared Unix-socket primitives. The kernel-provided peer identity is the only caller identity
/// accepted by the person-bound launch and credential protocols.
enum LocalSocket {
    struct Peer: Sendable, Hashable {
        var pid: Int32
        var uid: UInt32
    }

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

    /// Linux records pid, uid and gid at connect time. Other platforms return nil and callers
    /// refuse the request.
    static func peer(of connection: Int32) -> Peer? {
        #if canImport(Glibc)
        var fields = [UInt32](repeating: 0, count: 3)
        var size = socklen_t(MemoryLayout<UInt32>.size * 3)
        let result = fields.withUnsafeMutableBytes { raw in
            getsockopt(connection, SOL_SOCKET, SO_PEERCRED, raw.baseAddress, &size)
        }
        guard result == 0, size >= 8 else { return nil }
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
            case .socket(let code): "the local socket could not be made: \(String(cString: strerror(code)))"
            case .bind(let code): "the local socket could not be bound: \(String(cString: strerror(code)))"
            case .listen(let code): "the local socket could not listen: \(String(cString: strerror(code)))"
            case .pathTooLong(let limit): "a unix socket path is at most \(limit) characters"
            }
        }
    }
}
