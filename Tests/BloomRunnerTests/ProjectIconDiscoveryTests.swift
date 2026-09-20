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
    func configurationCompatibility() throws {
        for projectIcon in [nil, [:], ["should_discover": false]] as [[String: Any]?] {
            let configuration = try Self.configuration(projectIcon: projectIcon)
            try configuration.validate()
            #expect(configuration.projectIconRequest == nil)
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
    func reportEnvelope() {
        let icon = Data("canonical-png".utf8)
        let report = ProjectIconReport(
            requestedRevision: request.requestedRevision,
            detectorVersion: request.detectorVersion,
            sourceCommit: String(repeating: "b", count: 40),
            icon: icon
        )
        #expect(report.requestedRevision == 3)
        #expect(report.detectorVersion == 1)
        #expect(report.sourceCommit == String(repeating: "b", count: 40))
        #expect(report.icon == icon)
        #expect(report.iconSHA256 == "d33a5e3a7ed7cc0d9db661342609a33db44f10cdab3cc1cd5c3ed833b52c3d22")
    }

    @Test("a successfully reported revision is not rediscovered after a Runner restart")
    func completedRevision() async throws {
        let stored = Mutex<String?>(nil)
        let calls = Mutex<[String]>([])
        let makeMonitor = {
            ProjectIconDiscoveryMonitor(
                repositoryPath: "/repo",
                loadRequest: {
                    ProjectIconRequestPoll(
                        projectIcon: MachineConfiguration.ProjectIcon(
                            requestedRevision: self.request.requestedRevision,
                            detectorVersion: self.request.detectorVersion,
                            repositoryDefaultBranch: self.request.repositoryDefaultBranch,
                            shouldDiscover: true
                        ),
                        pollAfter: .seconds(300)
                    )
                },
                inspect: { _, _ in
                    calls.withLock { $0.append("inspect") }
                    return ProjectIconInspection(sourceCommit: String(repeating: "e", count: 40), icon: nil)
                },
                report: { _ in calls.withLock { $0.append("report") } },
                loadState: { stored.withLock { $0 } },
                saveState: { value in stored.withLock { $0 = value } }
            )
        }

        #expect(await makeMonitor().refresh() == .reported)
        #expect(await makeMonitor().refresh() == .alreadyReported)
        #expect(calls.withLock { $0 } == ["inspect", "report"])
        #expect(stored.withLock { $0 }?.contains(#""requestedRevision":3"#) == true)
    }

    @Test("shutdown cancellation waits for inspection and prevents a late report")
    func lifecycleCancellation() async throws {
        let gate = ProjectIconDiscoveryGate()
        let reports = Mutex<[ProjectIconReport]>([])
        let monitor = ProjectIconDiscoveryMonitor(
            repositoryPath: "/repo",
            loadRequest: {
                ProjectIconRequestPoll(
                    projectIcon: MachineConfiguration.ProjectIcon(
                        requestedRevision: self.request.requestedRevision,
                        detectorVersion: self.request.detectorVersion,
                        repositoryDefaultBranch: self.request.repositoryDefaultBranch,
                        shouldDiscover: true
                    ),
                    pollAfter: .seconds(300)
                )
            },
            inspect: { _, _ in
                await gate.hold()
                try Task.checkCancellation()
                return ProjectIconInspection(sourceCommit: String(repeating: "d", count: 40), icon: nil)
            },
            report: { report in reports.withLock { $0.append(report) } }
        )
        let task = Task { await monitor.refresh() }
        await gate.waitUntilHeld()
        let stopping = Task { await monitor.stop() }
        await gate.release()
        await stopping.value

        #expect(await task.value == .stopped)
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

@Suite("Running project icon refresh")
struct ProjectIconDiscoveryMonitorTests {
    @Test("persisted PNG validation checks canonical structure and compressed pixels")
    func persistedPNGValidation() {
        #expect(ProjectIconPNGNormalizer.isCanonical(Self.canonicalPNG))

        var invalidDeflate = Self.canonicalPNG
        let idatLength = Int(Self.readBigEndianUInt32(invalidDeflate, at: 33))
        invalidDeflate[43] ^= 0xff
        var checked = Data("IDAT".utf8)
        checked.append(invalidDeflate[41..<(41 + idatLength)])
        Self.writeBigEndianUInt32(Self.crc32(checked), to: &invalidDeflate, at: 41 + idatLength)
        #expect(!ProjectIconPNGNormalizer.isCanonical(invalidDeflate))
    }

    @Test("a running machine discovers a newly requested revision and stops when it resolves")
    func refreshWhileRunning() async {
        let revision = Mutex(1)
        let inspections = Mutex<[Int]>([])
        let reports = Mutex<[Int]>([])
        let monitor = ProjectIconDiscoveryMonitor(
            repositoryPath: "/repo",
            loadRequest: {
                Self.poll(revision: revision.withLock { $0 }, shouldDiscover: revision.withLock { $0 < 3 })
            },
            inspect: { request, _ in
                inspections.withLock { $0.append(request.requestedRevision) }
                return Self.inspection(request.requestedRevision)
            },
            report: { report in reports.withLock { $0.append(report.requestedRevision) } }
        )

        #expect(await monitor.refresh() == .reported)
        revision.withLock { $0 = 2 }
        #expect(await monitor.refresh() == .reported)
        revision.withLock { $0 = 3 }
        #expect(await monitor.refresh() == .noRequest)
        #expect(inspections.withLock { $0 } == [1, 2])
        #expect(reports.withLock { $0 } == [1, 2])
    }

    @Test("duplicate, out-of-order and future-detector answers cannot replace newer work")
    func ordering() async {
        let answers = Mutex([
            Self.poll(revision: 4),
            Self.poll(revision: 4),
            Self.poll(revision: 4, shouldDiscover: false),
            Self.poll(revision: 4),
            Self.poll(revision: 3),
            Self.poll(revision: 5, detectorVersion: 2),
            Self.poll(revision: 4),
            Self.poll(revision: 6),
        ])
        let inspections = Mutex<[Int]>([])
        let monitor = ProjectIconDiscoveryMonitor(
            repositoryPath: "/repo",
            loadRequest: { answers.withLock { $0.removeFirst() } },
            inspect: { request, _ in
                inspections.withLock { $0.append(request.requestedRevision) }
                return Self.inspection(request.requestedRevision)
            },
            report: { _ in }
        )

        #expect(await monitor.refresh() == .reported)
        #expect(await monitor.refresh() == .alreadyReported)
        #expect(await monitor.refresh() == .noRequest)
        #expect(await monitor.refresh() == .stale)
        #expect(await monitor.refresh() == .stale)
        #expect(await monitor.refresh() == .unsupportedDetector)
        #expect(await monitor.refresh() == .stale)
        #expect(await monitor.refresh() == .reported)
        #expect(inspections.withLock { $0 } == [4, 6])
    }

    @Test("a failed report retries the identical durable result with isolated state writes")
    func idempotentRetryAndWriteIsolation() async {
        let inspections = Mutex(0)
        let attempts = Mutex<[ProjectIconReport]>([])
        let writes = Mutex<[String]>([])
        let monitor = ProjectIconDiscoveryMonitor(
            repositoryPath: "/repo",
            loadRequest: { Self.poll(revision: 7) },
            inspect: { request, _ in
                inspections.withLock { $0 += 1 }
                return Self.inspection(request.requestedRevision)
            },
            report: { report in
                let attempt = attempts.withLock { attempts -> Int in
                    attempts.append(report)
                    return attempts.count
                }
                if attempt == 1 { throw RunbloomError.unreachable("offline") }
            },
            saveState: { value in writes.withLock { $0.append(value) } }
        )

        #expect(await monitor.refresh() == .retryPending)
        #expect(writes.withLock { $0 }.count == 2, "authority and exact prepared report persist before PUT")
        #expect(writes.withLock { $0 }.last?.contains(#""prepared""#) == true)
        #expect(await monitor.refresh() == .alreadyReported, "the retry is followed by an authenticated reload")
        #expect(inspections.withLock { $0 } == 1)
        let sent = attempts.withLock { $0 }
        #expect(sent.count == 2)
        #expect(sent.first == sent.last)
        #expect(writes.withLock { $0 }.count == 3)
        #expect(writes.withLock { $0 }.last?.contains(#""completed""#) == true)
    }

    @Test("a restart cannot regress a completed revision to its stale bootstrap request")
    func staleBootstrapAfterRestart() async {
        let stored = Mutex<String?>(nil)
        let inspections = Mutex<[Int]>([])
        let reports = Mutex<[Int]>([])
        let first = ProjectIconDiscoveryMonitor(
            repositoryPath: "/repo",
            loadRequest: { Self.poll(revision: 2) },
            inspect: { request, _ in
                inspections.withLock { $0.append(request.requestedRevision) }
                return Self.inspection(request.requestedRevision)
            },
            report: { report in reports.withLock { $0.append(report.requestedRevision) } },
            loadState: { stored.withLock { $0 } },
            saveState: { value in stored.withLock { $0 = value } }
        )
        #expect(await first.refresh() == .reported)

        let pauses = ProjectIconPollGate()
        let restarted = ProjectIconDiscoveryMonitor(
            repositoryPath: "/repo",
            loadRequest: { Self.poll(revision: 2, shouldDiscover: false) },
            inspect: { request, _ in
                inspections.withLock { $0.append(request.requestedRevision) }
                return Self.inspection(request.requestedRevision)
            },
            report: { report in reports.withLock { $0.append(report.requestedRevision) } },
            loadState: { stored.withLock { $0 } },
            saveState: { value in stored.withLock { $0 = value } },
            pause: { try await pauses.pause($0) }
        )
        await restarted.start(initialRequest: ProjectIconDiscoveryRequest(
            requestedRevision: 1,
            detectorVersion: 1,
            repositoryDefaultBranch: "main"
        ))
        await pauses.waitForCount(1)

        #expect(inspections.withLock { $0 } == [2])
        #expect(reports.withLock { $0 } == [2])
        #expect(stored.withLock { $0 }?.contains(#""requestedRevision":1"#) != true)
        #expect(stored.withLock { $0 }?.contains(#""requestedRevision":2"#) == true)
        await restarted.stop()
    }

    @Test("the legacy completion marker remains a monotonic floor after upgrade")
    func legacyCompletionMarker() async {
        let reports = Mutex(0)
        let monitor = ProjectIconDiscoveryMonitor(
            repositoryPath: "/repo",
            loadRequest: { Self.poll(revision: 4) },
            inspect: { request, _ in Self.inspection(request.requestedRevision) },
            report: { _ in reports.withLock { $0 += 1 } },
            loadState: { "1:5:main" }
        )

        #expect(await monitor.refresh() == .stale)
        #expect(reports.withLock { $0 } == 0)
    }

    @Test("out-of-range and cross-field-corrupt durable state fails closed")
    func corruptStateFailsClosed() async {
        let commit = String(repeating: "a", count: 40)
        var corrupt = [
            "65536:1:main",
            "1:4294967296:main",
            #"{"version":1,"highestRevision":4294967296,"latestShouldDiscover":false,"noProjectAtHighestRevision":true}"#,
            #"{"version":1,"highestRevision":2,"latestRequest":{"requestedRevision":1,"detectorVersion":1,"repositoryDefaultBranch":"main"},"latestShouldDiscover":true,"noProjectAtHighestRevision":false}"#,
            #"{"version":1,"highestRevision":2,"latestRequest":{"requestedRevision":2,"detectorVersion":1,"repositoryDefaultBranch":"main"},"latestShouldDiscover":true,"noProjectAtHighestRevision":false,"prepared":{"request":{"requestedRevision":2,"detectorVersion":1,"repositoryDefaultBranch":"develop"},"report":{"requestedRevision":2,"detectorVersion":1,"sourceCommit":"\#(commit)","icon":null}}}"#,
            #"{"version":1,"highestRevision":2,"latestRequest":{"requestedRevision":2,"detectorVersion":1,"repositoryDefaultBranch":"develop"},"latestShouldDiscover":true,"noProjectAtHighestRevision":false,"completed":{"requestedRevision":2,"detectorVersion":1,"repositoryDefaultBranch":"main"},"prepared":{"request":{"requestedRevision":2,"detectorVersion":1,"repositoryDefaultBranch":"develop"},"report":{"requestedRevision":2,"detectorVersion":1,"sourceCommit":"\#(commit)","icon":null}}}"#,
            #"{"version":1,"highestRevision":2,"latestRequest":{"requestedRevision":2,"detectorVersion":1,"repositoryDefaultBranch":"main"},"latestShouldDiscover":true,"noProjectAtHighestRevision":false,"prepared":{"request":{"requestedRevision":2,"detectorVersion":1,"repositoryDefaultBranch":"main"},"report":{"requestedRevision":2,"detectorVersion":1,"sourceCommit":"\#(commit)","icon":"bm90LWEtY2Fub25pY2FsLXBuZw=="}}}"#,
        ]
        var corruptPNG = Self.canonicalPNG
        corruptPNG[corruptPNG.count - 1] ^= 0xff
        corrupt.append(
            #"{"version":1,"highestRevision":2,"latestRequest":{"requestedRevision":2,"detectorVersion":1,"repositoryDefaultBranch":"main"},"latestShouldDiscover":true,"noProjectAtHighestRevision":false,"prepared":{"request":{"requestedRevision":2,"detectorVersion":1,"repositoryDefaultBranch":"main"},"report":{"requestedRevision":2,"detectorVersion":1,"sourceCommit":"\#(commit)","icon":"\#(corruptPNG.base64EncodedString())"}}}"#
        )

        for stored in corrupt {
            let loads = Mutex(0)
            let reports = Mutex(0)
            let writes = Mutex(0)
            let monitor = ProjectIconDiscoveryMonitor(
                repositoryPath: "/repo",
                loadRequest: {
                    loads.withLock { $0 += 1 }
                    return Self.poll(revision: 3)
                },
                inspect: { request, _ in Self.inspection(request.requestedRevision) },
                report: { _ in reports.withLock { $0 += 1 } },
                loadState: { stored },
                saveState: { _ in writes.withLock { $0 += 1 } }
            )

            #expect(await monitor.refresh() == .retryPending)
            #expect(loads.withLock { $0 } == 0)
            #expect(reports.withLock { $0 } == 0)
            #expect(writes.withLock { $0 } == 0)
        }
    }

    @Test("a restart after PUT but before completion retries the durable report byte for byte")
    func durablePreparedReportRetry() async {
        let stored = Mutex<String?>(nil)
        let completionSaveFails = Mutex(true)
        let inspections = Mutex<[Int]>([])
        let reports = Mutex<[ProjectIconReport]>([])
        let save: @Sendable (String) async throws -> Void = { value in
            if value.contains(#""completed""#), !value.contains(#""prepared""#),
               completionSaveFails.withLock({ $0 }) {
                completionSaveFails.withLock { $0 = false }
                throw CocoaError(.fileWriteUnknown)
            }
            stored.withLock { $0 = value }
        }
        let icon = Self.canonicalPNG
        let first = ProjectIconDiscoveryMonitor(
            repositoryPath: "/repo",
            loadRequest: { Self.poll(revision: 8) },
            inspect: { request, _ in
                inspections.withLock { $0.append(request.requestedRevision) }
                return ProjectIconInspection(sourceCommit: String(repeating: "a", count: 40), icon: icon)
            },
            report: { report in reports.withLock { $0.append(report) } },
            loadState: { stored.withLock { $0 } },
            saveState: save
        )
        #expect(await first.refresh() == .retryPending)
        #expect(stored.withLock { $0 }?.contains(#""prepared""#) == true)

        let loadsAfterRestart = Mutex(0)
        let restarted = ProjectIconDiscoveryMonitor(
            repositoryPath: "/repo",
            loadRequest: {
                loadsAfterRestart.withLock { $0 += 1 }
                return Self.poll(revision: 9)
            },
            inspect: { request, _ in
                inspections.withLock { $0.append(request.requestedRevision) }
                return ProjectIconInspection(sourceCommit: String(repeating: "b", count: 40), icon: Data("changed".utf8))
            },
            report: { report in reports.withLock { $0.append(report) } },
            loadState: { stored.withLock { $0 } },
            saveState: save
        )
        #expect(await restarted.refresh() == .reported)

        let sent = reports.withLock { $0 }
        #expect(sent.count == 3)
        #expect(sent[0] == sent[1], "the durable retry is byte-identical")
        #expect(sent[2].requestedRevision == 9, "the promised GET discovers newer authority after stale 204")
        #expect(inspections.withLock { $0 } == [8, 9])
        #expect(loadsAfterRestart.withLock { $0 } == 1)
        #expect(stored.withLock { $0 }?.contains(#""prepared""#) != true)
    }

    @Test("report feature refusals replace a long server cadence with five-minute recovery")
    func reportRefusalCadence() async {
        for status in [403, 404] {
            let pauses = ProjectIconPollGate()
            let monitor = ProjectIconDiscoveryMonitor(
                repositoryPath: "/repo",
                loadRequest: { Self.poll(revision: status, after: .seconds(86_400)) },
                inspect: { request, _ in Self.inspection(request.requestedRevision) },
                report: { _ in
                    throw RunbloomError.refused(
                        status: status, code: "feature_off", message: "Unavailable.",
                        limit: nil, retryAfter: nil
                    )
                },
                pause: { try await pauses.pause($0) }
            )

            await monitor.start(initialRequest: nil)
            await pauses.waitForCount(1)
            #expect(await pauses.recorded == [.seconds(300)])
            await monitor.stop()
        }
    }

    @Test("wake replaces a captured long pause when its report installs refusal backoff")
    func wakeReplacesLongPauseWithReportRefusalCadence() async {
        for status in [403, 404] {
            let pauses = ProjectIconPollGate()
            let refusingReport = ProjectIconDiscoveryGate()
            let loads = Mutex(0)
            let reports = Mutex<[ProjectIconReport]>([])
            let monitor = ProjectIconDiscoveryMonitor(
                repositoryPath: "/repo",
                loadRequest: {
                    let call = loads.withLock { value -> Int in
                        value += 1
                        return value
                    }
                    switch call {
                    case 1: return Self.poll(revision: status, shouldDiscover: false, after: .seconds(86_400))
                    case 2: return Self.poll(revision: status + 1, after: .seconds(86_400))
                    default: return Self.poll(revision: status + 1, shouldDiscover: false)
                    }
                },
                inspect: { request, _ in Self.inspection(request.requestedRevision) },
                report: { report in
                    let attempt = reports.withLock { value -> Int in
                        value.append(report)
                        return value.count
                    }
                    if attempt == 1 {
                        await refusingReport.hold()
                        throw RunbloomError.refused(
                            status: status, code: "feature_off", message: "Unavailable.",
                            limit: nil, retryAfter: nil
                        )
                    }
                },
                pause: { try await pauses.pause($0) }
            )

            await monitor.start(initialRequest: nil)
            await pauses.waitForCount(1)
            let wake = Task { await monitor.woke() }
            await refusingReport.waitUntilHeld()
            await refusingReport.release()
            await wake.value
            await pauses.waitForCount(2)

            #expect(await pauses.recorded == [.seconds(86_400), .seconds(300)])
            #expect(loads.withLock { $0 } == 2)
            #expect(reports.withLock { $0.count } == 1)

            await pauses.releaseFirst()
            await pauses.waitForCount(3)
            let sent = reports.withLock { $0 }
            #expect(sent.count == 2)
            #expect(sent.first == sent.last, "the exact prepared report retried after the refusal cadence")
            #expect(loads.withLock { $0 } == 3, "the successful retry was followed by authenticated GET")
            await monitor.stop()
        }
    }

    @Test("a refusal from a freshly inspected report gates its queued reload")
    func freshReportRefusalGatesQueuedReload() async {
        for status in [403, 404] {
            let reportGate = ProjectIconDiscoveryGate()
            let coalesced = ProjectIconCoalescingGate(target: 1)
            let pauses = ProjectIconPollGate()
            let loads = Mutex(0)
            let reports = Mutex<[ProjectIconReport]>([])
            let monitor = ProjectIconDiscoveryMonitor(
                repositoryPath: "/repo",
                loadRequest: {
                    loads.withLock { $0 += 1 }
                    return Self.poll(revision: status)
                },
                inspect: { request, _ in Self.inspection(request.requestedRevision) },
                report: { report in
                    let attempt = reports.withLock { value -> Int in
                        value.append(report)
                        return value.count
                    }
                    if attempt == 1 {
                        await reportGate.hold()
                        throw RunbloomError.refused(
                            status: status, code: "feature_off", message: "Unavailable.",
                            limit: nil, retryAfter: nil
                        )
                    }
                },
                pause: { try await pauses.pause($0) },
                observeCoalesced: { await coalesced.hold() }
            )

            await monitor.start(initialRequest: nil)
            await reportGate.waitUntilHeld()
            let overlapping = Task { await monitor.refresh() }
            await coalesced.waitUntilAllHeld()
            await coalesced.releaseAll()
            await reportGate.release()
            #expect(await overlapping.value == .refused)
            await pauses.waitForCount(1)

            #expect(await pauses.recorded == [.seconds(300)])
            #expect(loads.withLock { $0 } == 1)
            #expect(reports.withLock { $0.count } == 1)

            await pauses.releaseFirst()
            await pauses.waitForCount(2)
            let sent = reports.withLock { $0 }
            #expect(sent.count == 2)
            #expect(sent.first == sent.last)
            #expect(loads.withLock { $0 } == 2)
            await monitor.stop()
        }
    }

    @Test("prepared report refusal gates bootstrap and overlapping retries until cadence")
    func preparedReportRefusalBackoff() async {
        for status in [403, 404] {
            let stored = Mutex<String?>(nil)
            let seed = ProjectIconDiscoveryMonitor(
                repositoryPath: "/repo",
                loadRequest: { Self.poll(revision: status) },
                inspect: { request, _ in Self.inspection(request.requestedRevision) },
                report: { _ in throw RunbloomError.unreachable("response lost") },
                loadState: { stored.withLock { $0 } },
                saveState: { value in stored.withLock { $0 = value } }
            )
            #expect(await seed.refresh() == .retryPending)

            let firstReport = ProjectIconDiscoveryGate()
            let cadenceReport = ProjectIconDiscoveryGate()
            let coalesced = ProjectIconCoalescingGate(target: 1)
            let pauses = ProjectIconPollGate()
            let reports = Mutex(0)
            let loads = Mutex(0)
            let monitor = ProjectIconDiscoveryMonitor(
                repositoryPath: "/repo",
                loadRequest: {
                    loads.withLock { $0 += 1 }
                    return Self.poll(revision: status, shouldDiscover: false)
                },
                inspect: { request, _ in Self.inspection(request.requestedRevision) },
                report: { _ in
                    let attempt = reports.withLock { value -> Int in
                        value += 1
                        return value
                    }
                    if attempt == 1 {
                        await firstReport.hold()
                        throw RunbloomError.refused(
                            status: status, code: "feature_off", message: "Unavailable.",
                            limit: nil, retryAfter: nil
                        )
                    }
                    await cadenceReport.hold()
                },
                loadState: { stored.withLock { $0 } },
                saveState: { value in stored.withLock { $0 = value } },
                pause: { try await pauses.pause($0) },
                observeCoalesced: { await coalesced.hold() }
            )

            await monitor.start(initialRequest: ProjectIconDiscoveryRequest(
                requestedRevision: 1,
                detectorVersion: 1,
                repositoryDefaultBranch: "main"
            ))
            await firstReport.waitUntilHeld()
            let overlapping = Task { await monitor.refresh() }
            await coalesced.waitUntilAllHeld()
            await coalesced.releaseAll()
            await firstReport.release()
            #expect(await overlapping.value == .refused)
            await pauses.waitForCount(1)
            #expect(reports.withLock { $0 } == 1, "bootstrap and overlap did not bypass refusal backoff")
            #expect(loads.withLock { $0 } == 0)
            #expect(await pauses.recorded == [.seconds(300)])

            await pauses.releaseFirst()
            await cadenceReport.waitUntilHeld()
            #expect(reports.withLock { $0 } == 2)
            await cadenceReport.release()
            await pauses.waitForCount(2)
            #expect(loads.withLock { $0 } == 1, "successful cadence retry performed its authenticated GET")
            await monitor.stop()
        }
    }

    @Test("a report rejected for a replaced machine terminates discovery")
    func reportReplacementIsTerminal() async {
        let reports = Mutex(0)
        let monitor = ProjectIconDiscoveryMonitor(
            repositoryPath: "/repo",
            loadRequest: { Self.poll(revision: 12) },
            inspect: { request, _ in Self.inspection(request.requestedRevision) },
            report: { _ in
                reports.withLock { $0 += 1 }
                throw RunbloomError.refused(
                    status: 401, code: "invalid_workspace_secret", message: "This machine was replaced.",
                    limit: nil, retryAfter: nil
                )
            }
        )

        #expect(await monitor.refresh() == .refused)
        #expect(await monitor.refresh() == .stopped)
        #expect(reports.withLock { $0 } == 1)
    }

    @Test("durable icon state changes only its one Store setting")
    func storeWriteIsolation() async throws {
        let root = try SetupTestSupport.directory("project-icon-state")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = try Store(path: root + "/bloom.sqlite")
        try await store.setSetting("unrelated", "keep")
        let monitor = ProjectIconDiscoveryMonitor(
            repositoryPath: "/repo",
            loadRequest: { Self.poll(revision: 14) },
            inspect: { request, _ in Self.inspection(request.requestedRevision) },
            report: { _ in },
            loadState: { try await store.setting(ProjectIconDiscoveryMonitor.stateSetting) },
            saveState: { try await store.setSetting(ProjectIconDiscoveryMonitor.stateSetting, $0) }
        )

        #expect(await monitor.refresh() == .reported)
        #expect(try await store.setting("unrelated") == "keep")
        #expect(try await store.setting(ProjectIconDiscoveryMonitor.stateSetting)?.contains(#""completed""#) == true)
    }

    @Test("offline and feature refusals confer no authority or immediate retry")
    func refusalAndReplacement() async {
        let loads = Mutex(0)
        let inspections = Mutex(0)
        let monitor = ProjectIconDiscoveryMonitor(
            repositoryPath: "/repo",
            loadRequest: {
                let call = loads.withLock { value -> Int in
                    value += 1
                    return value
                }
                switch call {
                case 1: throw RunbloomError.unreachable("offline")
                case 2: throw RunbloomError.refused(
                    status: 403, code: "github_disabled", message: "GitHub access is disabled.",
                    limit: nil, retryAfter: nil
                )
                default: return Self.poll(revision: 3)
                }
            },
            inspect: { request, _ in
                inspections.withLock { $0 += 1 }
                return Self.inspection(request.requestedRevision)
            },
            report: { _ in }
        )

        #expect(await monitor.refresh() == .retryPending)
        #expect(await monitor.refresh() == .refused)
        #expect(await monitor.refresh() == .refused)
        #expect(loads.withLock { $0 } == 2)
        #expect(inspections.withLock { $0 } == 0)
    }

    @Test("concurrent refresh hints share one authenticated load and discovery")
    func concurrentRefreshCoalesces() async {
        let gate = ProjectIconDiscoveryGate()
        let coalesced = ProjectIconCoalescingGate(target: 8)
        let loads = Mutex(0)
        let inspections = Mutex(0)
        let monitor = ProjectIconDiscoveryMonitor(
            repositoryPath: "/repo",
            loadRequest: {
                loads.withLock { $0 += 1 }
                await gate.hold()
                return Self.poll(revision: 9)
            },
            inspect: { request, _ in
                inspections.withLock { $0 += 1 }
                return Self.inspection(request.requestedRevision)
            },
            report: { _ in },
            observeCoalesced: { await coalesced.hold() }
        )

        let first = Task { await monitor.refresh() }
        await gate.waitUntilHeld()
        let others = (0..<8).map { _ in Task { await monitor.refresh() } }
        await coalesced.waitUntilAllHeld()
        await gate.release()
        await coalesced.releaseAll()

        #expect(await first.value == .reported)
        for task in others { #expect(await task.value == .reported) }
        #expect(loads.withLock { $0 } == 1)
        #expect(inspections.withLock { $0 } == 1)
    }

    @Test("a refresh arriving after authority loaded queues one follow-up instead of being lost")
    func refreshDuringInspection() async {
        let inspectionGate = ProjectIconDiscoveryGate()
        let coalesced = ProjectIconCoalescingGate(target: 1)
        let revision = Mutex(1)
        let loads = Mutex(0)
        let reports = Mutex<[Int]>([])
        let monitor = ProjectIconDiscoveryMonitor(
            repositoryPath: "/repo",
            loadRequest: {
                loads.withLock { $0 += 1 }
                return Self.poll(revision: revision.withLock { $0 })
            },
            inspect: { request, _ in
                if request.requestedRevision == 1 { await inspectionGate.hold() }
                return Self.inspection(request.requestedRevision)
            },
            report: { report in reports.withLock { $0.append(report.requestedRevision) } },
            observeCoalesced: { await coalesced.hold() }
        )

        let first = Task { await monitor.refresh() }
        await inspectionGate.waitUntilHeld()
        revision.withLock { $0 = 2 }
        let concurrent = Task { await monitor.refresh() }
        await coalesced.waitUntilAllHeld()
        await coalesced.releaseAll()
        await inspectionGate.release()

        #expect(await first.value == .reported)
        _ = await concurrent.value
        #expect(loads.withLock { $0 } == 2)
        #expect(reports.withLock { $0 } == [1, 2])
    }

    @Test("polling honours retry-after, stays quiet while asleep and restarts its interval on wake")
    func pollingLifecycle() async {
        let pauses = ProjectIconPollGate()
        let awake = Mutex(false)
        let loads = Mutex(0)
        let monitor = ProjectIconDiscoveryMonitor(
            repositoryPath: "/repo",
            loadRequest: {
                let call = loads.withLock { value -> Int in
                    value += 1
                    return value
                }
                if call == 1 { throw ProjectIconRequestUnavailable(retryAfter: .seconds(60)) }
                return ProjectIconRequestPoll(projectIcon: nil, pollAfter: .seconds(300))
            },
            report: { _ in },
            pause: { try await pauses.pause($0) },
            isAwake: { awake.withLock { $0 } }
        )

        await monitor.start(initialRequest: nil)
        await pauses.waitForCount(1)
        #expect(await pauses.recorded == [.seconds(60)])

        await pauses.releaseFirst()
        await pauses.waitForCount(2)
        #expect(loads.withLock { $0 } == 1, "an elapsed timer does not poll an asleep machine")

        awake.withLock { $0 = true }
        await monitor.woke()
        await pauses.waitForCount(3)
        #expect(loads.withLock { $0 } == 2)
        #expect(await pauses.recorded == [.seconds(60), .seconds(60), .seconds(300)])
        await monitor.stop()
    }

    private static func poll(
        revision: Int,
        detectorVersion: Int = 1,
        shouldDiscover: Bool = true,
        after: Duration = .seconds(300)
    ) -> ProjectIconRequestPoll {
        ProjectIconRequestPoll(
            projectIcon: MachineConfiguration.ProjectIcon(
                requestedRevision: revision,
                detectorVersion: detectorVersion,
                repositoryDefaultBranch: "main",
                shouldDiscover: shouldDiscover
            ),
            pollAfter: after
        )
    }

    private static func inspection(_ revision: Int) -> ProjectIconInspection {
        ProjectIconInspection(sourceCommit: String(repeating: String(revision % 10), count: 40), icon: nil)
    }

    private static let canonicalPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAQAAAAEACAYAAABccqhmAAABFUlEQVR42u3BMQEAAADCoPVP7WsIoAAAAAAAAAAAAAAAAAAAAAAA"
            + "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            + "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            + "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
            + "AAAAAAAAAAAAAAAAeAMBPAAB2ClDBAAAAABJRU5ErkJggg=="
    )!

    private static func readBigEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func writeBigEndianUInt32(_ value: UInt32, to data: inout Data, at offset: Int) {
        data.replaceSubrange(offset..<(offset + 4), with: [
            UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff),
            UInt8(value >> 8 & 0xff), UInt8(value & 0xff),
        ])
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xffff_ffff
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = (value & 1) == 1 ? (value >> 1) ^ 0xedb8_8320 : value >> 1 }
        }
        return value ^ 0xffff_ffff
    }
}

private actor ProjectIconPollGate {
    private struct Waiter {
        var id: UUID
        var continuation: CheckedContinuation<Void, any Error>
    }

    private var durations: [Duration] = []
    private var waiters: [Waiter] = []
    private var observers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var recorded: [Duration] { durations }

    func pause(_ duration: Duration) async throws {
        let id = UUID()
        durations.append(duration)
        resumeObservers()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func waitForCount(_ count: Int) async {
        guard durations.count < count else { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }

    func releaseFirst() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().continuation.resume()
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func resumeObservers() {
        let ready = observers.filter { durations.count >= $0.count }
        observers.removeAll { durations.count >= $0.count }
        for observer in ready { observer.continuation.resume() }
    }
}

private actor ProjectIconCoalescingGate {
    private let target: Int
    private var held = 0
    private var arrival: CheckedContinuation<Void, Never>?
    private var releases: [CheckedContinuation<Void, Never>] = []

    init(target: Int) {
        self.target = target
    }

    func hold() async {
        held += 1
        if held == target {
            arrival?.resume()
            arrival = nil
        }
        await withCheckedContinuation { releases.append($0) }
    }

    func waitUntilAllHeld() async {
        guard held < target else { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func releaseAll() {
        let releases = self.releases
        self.releases = []
        for release in releases { release.resume() }
    }
}
