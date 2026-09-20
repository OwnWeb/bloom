import Foundation
import Synchronization
import Testing
@testable import BloomCore
@testable import BloomRunner

@Suite("Project icon discovery")
struct ProjectIconDiscoveryTests {
    private let request = ProjectIconDiscoveryRequest(
        requestedRevision: 3,
        detectorVersion: 1,
        repositoryDefaultBranch: "main"
    )

    @Test("old and disabled configurations never start discovery or report")
    func configurationCompatibility() async throws {
        for projectIcon in [nil, [:], ["should_discover": false]] as [[String: Any]?] {
            let configuration = try Self.configuration(projectIcon: projectIcon)
            try configuration.validate()
            #expect(configuration.projectIconRequest == nil)

            let calls = Mutex<[String]>([])
            let discovery = ProjectIconDiscovery(
                inspect: { _, _ in
                    calls.withLock { $0.append("inspect") }
                    return ProjectIconInspection(sourceCommit: String(repeating: "a", count: 40), icon: nil)
                },
                currentRequest: { nil },
                report: { _ in calls.withLock { $0.append("report") } }
            )
            let outcome = try await discovery.run(configuration.projectIconRequest, repositoryPath: "/unused")
            #expect(outcome == .notRequested)
            #expect(calls.withLock { $0 }.isEmpty)
        }
    }

    @Test("a complete enabled configuration becomes the exact revisioned request")
    func enabledConfiguration() throws {
        let configuration = try Self.configuration(projectIcon: [
            "requested_revision": 7,
            "detector_version": 2,
            "repository_default_branch": "develop",
            "should_discover": true,
        ])
        try configuration.validate()
        #expect(configuration.projectIconRequest == ProjectIconDiscoveryRequest(
            requestedRevision: 7,
            detectorVersion: 2,
            repositoryDefaultBranch: "develop"
        ))
    }

    @Test("an enabled malformed configuration is refused")
    func malformedConfiguration() throws {
        let malformed: [[String: Any]] = [
            ["requested_revision": 0, "detector_version": 1, "repository_default_branch": "main", "should_discover": true],
            ["requested_revision": 1, "detector_version": 0, "repository_default_branch": "main", "should_discover": true],
            ["requested_revision": 1, "detector_version": 1, "repository_default_branch": "-bad", "should_discover": true],
            ["should_discover": true],
        ]
        for projectIcon in malformed {
            let configuration = try Self.configuration(projectIcon: projectIcon)
            #expect(throws: MachineConfigurationError.self) { try configuration.validate() }
        }
    }

    @Test("the report carries the requested revision, detector, commit, pixels and digest")
    func reportEnvelope() async throws {
        let icon = Data("canonical-png".utf8)
        let reports = Mutex<[ProjectIconReport]>([])
        let discovery = ProjectIconDiscovery(
            inspect: { _, _ in ProjectIconInspection(sourceCommit: String(repeating: "b", count: 40), icon: icon) },
            currentRequest: { request },
            report: { report in reports.withLock { $0.append(report) } }
        )

        let outcome = try await discovery.run(request, repositoryPath: "/repo")

        #expect(outcome == .reported)
        let report = try #require(reports.withLock { $0 }.only)
        #expect(report.requestedRevision == 3)
        #expect(report.detectorVersion == 1)
        #expect(report.sourceCommit == String(repeating: "b", count: 40))
        #expect(report.icon == icon)
        #expect(report.iconSHA256 == "d33a5e3a7ed7cc0d9db661342609a33db44f10cdab3cc1cd5c3ed833b52c3d22")
    }

    @Test("a successfully reported revision is not rediscovered after a Runner restart")
    func completedRevision() async throws {
        let completed = Mutex<String?>(nil)
        let calls = Mutex<[String]>([])
        let discovery = ProjectIconDiscovery(
            inspect: { _, _ in
                calls.withLock { $0.append("inspect") }
                return ProjectIconInspection(sourceCommit: String(repeating: "e", count: 40), icon: nil)
            },
            currentRequest: { request },
            report: { _ in calls.withLock { $0.append("report") } },
            alreadyReported: { asked in completed.withLock { $0 == asked.completionMarker } },
            markReported: { reported in completed.withLock { $0 = reported.completionMarker } }
        )

        #expect(try await discovery.run(request, repositoryPath: "/repo") == .reported)
        #expect(try await discovery.run(request, repositoryPath: "/repo") == .alreadyReported)
        #expect(calls.withLock { $0 } == ["inspect", "report"])
        #expect(completed.withLock { $0 } == request.completionMarker)
    }

    @Test("a revision replaced during inspection never reaches the endpoint")
    func staleRevision() async throws {
        let current = Mutex<ProjectIconDiscoveryRequest?>(request)
        let reports = Mutex<[ProjectIconReport]>([])
        let replacement = ProjectIconDiscoveryRequest(
            requestedRevision: 4,
            detectorVersion: 1,
            repositoryDefaultBranch: "main"
        )
        let discovery = ProjectIconDiscovery(
            inspect: { _, _ in
                current.withLock { $0 = replacement }
                return ProjectIconInspection(sourceCommit: String(repeating: "c", count: 40), icon: nil)
            },
            currentRequest: { current.withLock { $0 } },
            report: { report in reports.withLock { $0.append(report) } }
        )

        let outcome = try await discovery.run(request, repositoryPath: "/repo")
        #expect(outcome == .stale)
        #expect(reports.withLock { $0 }.isEmpty)
    }

    @Test("shutdown cancellation waits for inspection and prevents a late report")
    func lifecycleCancellation() async throws {
        let gate = ProjectIconDiscoveryGate()
        let reports = Mutex<[ProjectIconReport]>([])
        let discovery = ProjectIconDiscovery(
            inspect: { _, _ in
                await gate.hold()
                try Task.checkCancellation()
                return ProjectIconInspection(sourceCommit: String(repeating: "d", count: 40), icon: nil)
            },
            currentRequest: { request },
            report: { report in reports.withLock { $0.append(report) } }
        )
        let task = Task { try await discovery.run(request, repositoryPath: "/repo") }
        await gate.waitUntilHeld()
        task.cancel()
        await gate.release()

        do {
            _ = try await task.value
            Issue.record("Cancelled discovery completed")
        } catch is CancellationError {
            // Expected lifecycle result.
        }
        #expect(reports.withLock { $0 }.isEmpty)
    }

    @Test("the snapshot reads origin default branch, not the checked out feature branch")
    func defaultBranchSnapshot() async throws {
        let root = try SetupTestSupport.directory("project-icon-snapshot")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let source = root + "/source"
        let worktree = root + "/worktree"
        try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: true)
        try SetupTestSupport.bash("git init -q -b main .", in: source)
        try Self.write(Self.detectorPNG(width: 64, height: 64), to: source + "/public/favicon.png")
        try SetupTestSupport.write(
            #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><path d="M0 0h64v64z"/></svg>"#,
            to: source + "/public/favicon.svg"
        )
        try SetupTestSupport.bash(Self.commit("main-icon"), in: source)
        try SetupTestSupport.bash("git checkout -q -b feature/icon", in: source)
        try Self.write(Self.detectorPNG(width: 512, height: 512), to: source + "/public/favicon.png")
        try SetupTestSupport.bash(Self.commit("feature-icon"), in: source)
        try SetupTestSupport.bash("git clone -q --bare source origin.git", in: root)
        try SetupTestSupport.bash("git clone -q origin.git worktree && git -C worktree checkout -q feature/icon", in: root)

        let captured = Mutex<String?>(nil)
        let inspection = try await ProjectIconSnapshot.inspect(request, repositoryPath: worktree) { candidate in
            captured.withLock { $0 = candidate.path }
            return try Data(contentsOf: URL(fileURLWithPath: candidate.path))
        }
        let expected = try SetupTestSupport.bash("git rev-parse refs/remotes/origin/main", in: worktree)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(inspection.sourceCommit == expected)
        #expect(inspection.icon == Self.detectorPNG(width: 64, height: 64))
        let temporaryCandidate = try #require(captured.withLock { $0 })
        #expect(!FileManager.default.fileExists(atPath: temporaryCandidate), "the temporary snapshot was removed")
        #expect(try SetupTestSupport.bash("git rev-parse --abbrev-ref HEAD", in: worktree)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "feature/icon")
    }

    @Test("Linux discovery cannot follow file, directory or manifest escapes")
    func snapshotConfinement() throws {
        let root = try SetupTestSupport.directory("project-icon-confinement")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repository = root + "/repository"
        let outside = root + "/outside"
        try Self.write(Self.detectorPNG(width: 64, height: 64), to: repository + "/public/favicon.png")
        try Self.write(Self.detectorPNG(width: 512, height: 512), to: outside + "/icon.png")
        try FileManager.default.createSymbolicLink(
            atPath: repository + "/public/icon.png",
            withDestinationPath: outside + "/icon.png"
        )
        try FileManager.default.createSymbolicLink(
            atPath: repository + "/assets",
            withDestinationPath: outside
        )
        try Data("""
        {"icons":[{"src":"../../outside/icon.png"}]}
        """.utf8).write(to: URL(fileURLWithPath: repository + "/public/manifest.json"))

        let candidates = RepoIconDetector.candidates(in: repository)
        #expect(candidates.map { ($0.path as NSString).lastPathComponent } == ["favicon.png"])
    }

    @Test("dark-only and notification-badged artwork keep the initials fallback")
    func unsuitableVariants() throws {
        for name in ["logo-dark.png", "favicon-unread-7.png", "icon-notification.png"] {
            let root = try SetupTestSupport.directory("project-icon-variant")
            defer { try? FileManager.default.removeItem(atPath: root) }
            try Self.write(Self.detectorPNG(width: 128, height: 128), to: root + "/public/" + name)
            #expect(RepoIconDetector.detect(in: root) == nil)
        }
    }

    @Test("the PNG decoder strips metadata and produces deterministic bounded RGBA")
    func canonicalPNG() async throws {
        let root = try SetupTestSupport.directory("project-icon-png")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = root + "/icon.png"
        let source = try #require(Data(base64Encoded: Self.validPNGBase64))
        try Self.write(source, to: path)
        let candidate = try #require(RepoIconDetector.detect(in: root))

        let first = try #require(try await ProjectIconPNGNormalizer.normalise(candidate, networkIsolated: false))
        let second = try #require(try await ProjectIconPNGNormalizer.normalise(candidate, networkIsolated: false))
        #expect(first == second)
        #expect(first.count <= ProjectIconPNGNormalizer.maximumBytes)
        #expect(Self.pngDimensions(first) == [256, 256])
        #expect(Self.pngChunkNames(first) == ["IHDR", "IDAT", "IEND"])
    }

    @Test("truncated, corrupt and oversized PNGs never become reports")
    func hostilePNGs() async throws {
        let root = try SetupTestSupport.directory("project-icon-hostile")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let valid = try #require(Data(base64Encoded: Self.validPNGBase64))
        var badCRC = valid
        badCRC[badCRC.count - 1] ^= 0xff
        let cases = [Data(valid.prefix(40)), badCRC, Data(repeating: 0, count: ProjectIconPNGNormalizer.maximumBytes + 1)]

        for (index, contents) in cases.enumerated() {
            let path = root + "/icon-\(index).png"
            try Self.write(Data(contents), to: path)
            let candidate = RepoIconCandidate(path: path, format: .png, origin: .brand, pixels: 64)
            #expect(try await ProjectIconPNGNormalizer.normalise(candidate, networkIsolated: false) == nil)
        }
    }

    @Test("the production decoder uses a network namespace and drops back to the Runner uid")
    func networkIsolation() {
        let command = ProjectIconPNGNormalizer.command(
            input: "/snapshot/icon.png",
            output: "/tmp/icon.png",
            networkIsolated: true,
            userID: 501,
            groupID: 20
        )
        #expect(command.executable == "sudo")
        #expect(Array(command.arguments.prefix(5)) == ["-n", "unshare", "--net", "--", "setpriv"])
        #expect(command.arguments.contains("--reuid=501"))
        #expect(command.arguments.contains("--regid=20"))
        #expect(command.arguments.contains("--clear-groups"))
        #expect(command.arguments.contains("-I"))
        #expect(command.arguments.contains("-S"))
    }

    private static func configuration(projectIcon: [String: Any]?) throws -> MachineConfiguration {
        var object: [String: Any] = [
            "workspace_id": "01k5bx7j9d3v2r8q6m4n0p1s2w",
            "issuer": "https://runbloom.test",
            "jwks_url": "https://runbloom.test/jwks",
            "base_url": "https://runbloom.test",
            "workspace_secret": "secret",
            "allowed_origins": [],
            "public_url": "https://bloom-test.sprites.app",
            "repository": "spatie/example",
            "branch": "feature/icon",
            "base_branch": "main",
            "name": "Project icon",
        ]
        if let projectIcon { object["project_icon"] = projectIcon }
        return try JSONDecoder().decode(
            MachineConfiguration.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
    }

    private static func commit(_ message: String) -> String {
        "git add -A && git -c user.name=Test -c user.email=test@bloom.local "
            + "-c commit.gpgsign=false commit -q -m \(message)"
    }

    private static func write(_ data: Data, to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// Header-complete data is enough for the detector. The injected normaliser reads it verbatim.
    private static func detectorPNG(width: Int, height: Int) -> Data {
        var data = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        var header = Data("IHDR".utf8)
        header.append(contentsOf: be32(UInt32(width)))
        header.append(contentsOf: be32(UInt32(height)))
        header.append(contentsOf: [8, 6, 0, 0, 0])
        data.append(contentsOf: be32(UInt32(header.count - 4)))
        data.append(header)
        data.append(contentsOf: be32(crc32(header)))
        data.append(contentsOf: be32(0))
        data.append(Data("IEND".utf8))
        data.append(contentsOf: be32(crc32(Data("IEND".utf8))))
        return data
    }

    private static func pngDimensions(_ data: Data) -> [Int] {
        guard data.count >= 24 else { return [] }
        return [Int(readBE32(data, 16)), Int(readBE32(data, 20))]
    }

    private static func pngChunkNames(_ data: Data) -> [String] {
        var names: [String] = []
        var offset = 8
        while offset + 12 <= data.count {
            let length = Int(readBE32(data, offset))
            guard offset + 12 + length <= data.count else { return [] }
            names.append(String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self))
            offset += 12 + length
        }
        return names
    }

    private static func readBE32(_ data: Data, _ offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 }
        }
        return crc ^ 0xffff_ffff
    }

    private static let validPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAAZUlEQVR42u3QQREAAAQAMAFVU9eXHM4eK7DI6vksBAgQIECAAAECBAgQIE"
        + "CAAAECBAgQIECAAAECBAgQIECAAAECBAgQIECAAAECBAgQIECAAAECBAgQIECAAAECBAgQIECAgPsWrCTilUzpQtAAAAAASUVORK5CYII="
}

private actor ProjectIconDiscoveryGate {
    private var held = false
    private var released = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func hold() async {
        held = true
        arrival?.resume()
        arrival = nil
        guard !released else { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilHeld() async {
        guard !held else { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
