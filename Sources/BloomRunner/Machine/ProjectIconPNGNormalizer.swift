import BloomCore
import CZlib
import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Turns one bounded PNG into the only shape the machine API accepts: a stripped 256 pixel RGBA
/// PNG on a transparent square. The decoder is a fixed script with no image delegates or URL
/// support. On the Linux machine it additionally runs in a network namespace with no interfaces.
public enum ProjectIconPNGNormalizer {
    static let maximumBytes = 512 * 1024
    static let invalidImageStatus: Int32 = 42

    /// Checks the exact bounded output shape produced by the fixed normaliser before durable bytes
    /// are trusted for a retry. This is deliberately stricter than ordinary PNG validation.
    static func isCanonical(_ data: Data) -> Bool {
        let signature = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        guard data.count <= maximumBytes, data.prefix(signature.count) == signature else { return false }

        var offset = signature.count
        var chunks: [(kind: String, contents: Data)] = []
        while offset <= data.count - 12 {
            let length = Int(readBigEndianUInt32(data, at: offset))
            guard length <= maximumBytes, offset <= data.count - 12 - length else { return false }
            let kindRange = (offset + 4)..<(offset + 8)
            let contentsRange = (offset + 8)..<(offset + 8 + length)
            let checksumOffset = offset + 8 + length
            let kind = Data(data[kindRange])
            let contents = Data(data[contentsRange])
            var checked = kind
            checked.append(contents)
            guard crc32(checked) == readBigEndianUInt32(data, at: checksumOffset) else { return false }
            chunks.append((String(decoding: kind, as: UTF8.self), contents))
            offset = checksumOffset + 4
        }

        guard offset == data.count,
              chunks.count == 3,
              chunks[0].kind == "IHDR",
              chunks[0].contents == Data([0, 0, 1, 0, 0, 0, 1, 0, 8, 6, 0, 0, 0]),
              chunks[1].kind == "IDAT", !chunks[1].contents.isEmpty,
              chunks[2].kind == "IEND", chunks[2].contents.isEmpty
        else { return false }

        let rowBytes = 256 * 4 + 1
        var decoded = [UInt8](repeating: 0, count: rowBytes * 256)
        var decodedCount = uLongf(decoded.count)
        let status = decoded.withUnsafeMutableBytes { destination in
            chunks[1].contents.withUnsafeBytes { source in
                uncompress(
                    destination.bindMemory(to: Bytef.self).baseAddress,
                    &decodedCount,
                    source.bindMemory(to: Bytef.self).baseAddress,
                    uLong(source.count)
                )
            }
        }
        guard status == Z_OK, decodedCount == decoded.count else { return false }
        return stride(from: 0, to: decoded.count, by: rowBytes).allSatisfy { decoded[$0] == 0 }
    }

    private static func readBigEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xffff_ffff
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = (value & 1) == 1 ? (value >> 1) ^ 0xedb8_8320 : value >> 1 }
        }
        return value ^ 0xffff_ffff
    }

    public static func normalise(_ candidate: RepoIconCandidate) async throws -> Data? {
        try await normalise(candidate, networkIsolated: usesNetworkNamespace)
    }

    static func normalise(_ candidate: RepoIconCandidate, networkIsolated: Bool) async throws -> Data? {
        guard candidate.format == .png else { return nil }

        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appendingPathComponent("bloom-project-icon-png-" + UUID().uuidString, isDirectory: true)
        let output = directory.appendingPathComponent("icon.png")
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? manager.removeItem(at: directory) }

        let command = command(
            input: candidate.path,
            output: output.path,
            networkIsolated: networkIsolated,
            userID: getuid(),
            groupID: getgid()
        )
        let result = try await Shell.run(
            command.executable,
            command.arguments,
            env: ["PYTHONHASHSEED": "0"],
            timeout: .seconds(30),
            outputLimit: 64 * 1024
        )
        if result.status == invalidImageStatus { return nil }
        guard result.ok else { throw ProjectIconDiscoveryError.normalisationFailed }

        guard let attributes = try? manager.attributesOfItem(atPath: output.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= maximumBytes,
              let data = try? Data(contentsOf: output),
              let measured = RepoIconDetector.detect(in: directory.path),
              measured.path == output.path, measured.format == .png, measured.pixels == 256
        else { throw ProjectIconDiscoveryError.normalisationFailed }
        return data
    }

    #if os(Linux)
    static let usesNetworkNamespace = true
    #else
    // Cloud runs on Linux. Keeping the same decoder reachable on a Mac makes the contract testable
    // without giving a local developer passwordless sudo merely to run the suite.
    static let usesNetworkNamespace = false
    #endif

    static func command(
        input: String,
        output: String,
        networkIsolated: Bool,
        userID: uid_t,
        groupID: gid_t
    ) -> (executable: String, arguments: [String]) {
        let python = ["python3", "-I", "-S", "-c", ProjectIconPNGScript.source, input, output]
        guard networkIsolated else { return (python[0], Array(python.dropFirst())) }
        return (
            "sudo",
            [
                "-n", "unshare", "--net", "--", "setpriv", "--reuid=\(userID)",
                "--regid=\(groupID)", "--clear-groups",
            ] + python
        )
    }
}
