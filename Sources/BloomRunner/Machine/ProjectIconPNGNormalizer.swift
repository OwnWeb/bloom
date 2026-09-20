import BloomCore
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
