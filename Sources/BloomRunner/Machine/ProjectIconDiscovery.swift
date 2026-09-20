#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import BloomCore
import Foundation

/// One revisioned answer to runbloom.app's project authority.
public struct ProjectIconReport: Sendable, Equatable {
    public var requestedRevision: Int
    public var detectorVersion: Int
    public var sourceCommit: String
    public var icon: Data?

    public init(requestedRevision: Int, detectorVersion: Int, sourceCommit: String, icon: Data?) {
        self.requestedRevision = requestedRevision
        self.detectorVersion = detectorVersion
        self.sourceCommit = sourceCommit
        self.icon = icon
    }

    public var iconSHA256: String? { icon.map(Self.sha256) }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ProjectIconInspection: Sendable, Equatable {
    public var sourceCommit: String
    public var icon: Data?

    public init(sourceCommit: String, icon: Data?) {
        self.sourceCommit = sourceCommit
        self.icon = icon
    }
}

/// A clean, temporary view of the repository authority's default branch.
///
/// `git archive` reads the local remote-tracking commit and cannot fetch. It also avoids checkout
/// filters and hooks, either of which would turn inspecting repository data into executing it.
public enum ProjectIconSnapshot {
    public typealias Normalise = @Sendable (RepoIconCandidate) async throws -> Data?

    public static func inspect(
        _ request: ProjectIconDiscoveryRequest,
        repositoryPath: String,
        normalise: Normalise = ProjectIconPNGNormalizer.normalise
    ) async throws -> ProjectIconInspection {
        guard Git.isValidBranchName(request.repositoryDefaultBranch) else {
            throw ProjectIconDiscoveryError.invalidDefaultBranch
        }

        let manager = FileManager.default
        let temporary = manager.temporaryDirectory
            .appendingPathComponent("bloom-project-icon-" + UUID().uuidString, isDirectory: true)
        let snapshot = temporary.appendingPathComponent("snapshot", isDirectory: true)
        let archive = temporary.appendingPathComponent("snapshot.tar")
        try manager.createDirectory(
            at: snapshot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? manager.removeItem(at: temporary) }

        let environment = [
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_TERMINAL_PROMPT": "0",
        ]
        let reference = "refs/remotes/origin/" + request.repositoryDefaultBranch
        let sourceCommit = try await Shell.check(
            "git", ["rev-parse", "--verify", "\(reference)^{commit}"],
            cwd: repositoryPath, env: environment, timeout: .seconds(30)
        ).trimmed
        guard sourceCommit.range(of: "^[0-9a-f]{40}([0-9a-f]{24})?$", options: .regularExpression) != nil else {
            throw ProjectIconDiscoveryError.invalidSourceCommit
        }

        try Task.checkCancellation()
        try await Shell.check(
            "git", ["archive", "--format=tar", "--output=\(archive.path)", sourceCommit],
            cwd: repositoryPath, env: environment, timeout: .seconds(30)
        )
        try await Shell.check(
            "tar", ["-xf", archive.path, "-C", snapshot.path],
            env: ["TZ": "UTC"], timeout: .seconds(30)
        )
        try Task.checkCancellation()

        var icon: Data?
        // The machine endpoint accepts only PNG. Keeping every other format out of the decoder is
        // also what makes SVG external references and image delegates irrelevant to this path.
        for candidate in RepoIconDetector.candidates(in: snapshot.path) where candidate.format == .png {
            if let normalised = try await normalise(candidate) {
                icon = normalised
                break
            }
        }
        return ProjectIconInspection(sourceCommit: sourceCommit, icon: icon)
    }
}

public enum ProjectIconDiscoveryError: Error, Sendable, Equatable {
    case invalidDefaultBranch
    case invalidSourceCommit
    case normalisationFailed
}

extension ProjectIconDiscoveryRequest {
    var completionMarker: String { "\(detectorVersion):\(requestedRevision):\(repositoryDefaultBranch)" }
}
