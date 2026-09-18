import Foundation
import Synchronization
import Testing
@testable import BloomCore
@testable import BloomRunner

/// Setup against a bare repository on disk standing in for GitHub, with real git and real scripts.
@Suite("Setting a machine's workspace up")
struct MachineSetupTests {
    final class Steps: Sendable {
        private let recorded = Mutex<[String]>([])
        var all: [String] { recorded.withLock { $0 } }
        func add(_ step: String) { recorded.withLock { $0.append(step) } }
    }

    struct Fixture {
        let root: String
        let origin: String
        let layout: MachineLayout
        let store: Store
        let runtime: WorkspaceRuntime
        let services: ServiceSupervisor
        let steps: Steps
        let orderFile: String
        let gitConfig: String

        func setup(timeouts: MachineSetup.Timeouts = .standard, origin: String? = nil,
                   stallAfter: TimeInterval = MachineSetup.stallAfter, runSetup: Bool? = nil) throws -> MachineSetup {
            // Written only when the test is about it, because the key being absent is the state
            // every machine bootstrapped before it existed is in, and that has to keep working.
            let runSetupKey = runSetup.map { ", \"run_setup\": \($0)" } ?? ""
            let configuration = try JSONDecoder().decode(MachineConfiguration.self, from: Data("""
            {"workspace_id": "01k5bx7j9d3v2r8q6m4n0p1s2w", "issuer": "https://runbloom.test", "jwks_url": "https://runbloom.test/jwks",
             "base_url": "https://runbloom.test", "workspace_secret": "secret", "allowed_origins": [],
             "public_url": "https://bloom-test.sprites.app", "repository": "spatie/example", "branch": "feature/queue",
             "base_branch": "main", "name": "Queue"\(runSetupKey)}
            """.utf8))
            let origin = origin ?? self.origin
            return MachineSetup(
                runtime: runtime, store: store, configuration: configuration, layout: layout,
                environment: MachineEnvironment { ["ORDER_FILE": orderFile, "TEAM_VALUE": "from the team"] },
                services: services, serverExecutable: root + "/fake-bloom-runner",
                cloneURL: { _ in origin }, gitGlobalConfig: gitConfig, timeouts: timeouts, stallAfter: stallAfter
            )
        }

        var worktree: String { layout.worktree }
        var order: [String] { SetupTestSupport.read(orderFile).split(separator: "\n").map(String.init) }

        func workspace() async throws -> Workspace {
            try #require(try await store.workspace(id: runtime.workspaceID))
        }
    }

    /// A repository with these files committed on `main`, pushed to a bare origin.
    func fixture(files: [String: String], executables: Set<String> = [], originBranches: [String: [String: String]] = [:]) async throws -> Fixture {
        let root = try SetupTestSupport.directory("machine-setup")
        let source = root + "/source"
        let origin = root + "/origin.git"
        try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: true)
        // Signing off, because the machine this runs on may sign every commit through an agent
        // that asks a person to approve it: this suite failed on a developer's Mac with
        // "1Password: agent returned an error" while passing in CI, which is a test depending on
        // whose laptop it is.
        let git = "git -c user.name=Test -c user.email=test@bloom.local -c commit.gpgsign=false -c tag.gpgsign=false"
        try SetupTestSupport.bash("git init -q -b main .", in: source)
        for (path, text) in files {
            try SetupTestSupport.write(text, to: source + "/" + path, executable: executables.contains(path))
        }
        try SetupTestSupport.bash("git add -A && \(git) commit -q -m start", in: source)
        for (branch, branchFiles) in originBranches {
            try SetupTestSupport.bash("git checkout -q -b \(branch)", in: source)
            for (path, text) in branchFiles { try SetupTestSupport.write(text, to: source + "/" + path) }
            try SetupTestSupport.bash("git add -A && \(git) commit -q -m \(branch.replacingOccurrences(of: "/", with: "-")) && git checkout -q main", in: source)
        }
        try SetupTestSupport.bash("git clone -q --bare source origin.git", in: root)

        let layout = MachineLayout(dataDirectory: root + "/data", worktree: root + "/workspace", appPort: 3017)
        let store = try Store(path: root + "/bloom.sqlite")
        let workspace = try await RemoteMachineWorkspace.ensure(
            store: store, id: "01k5bx7j9d3v2r8q6m4n0p1s2w", name: "Queue", repository: "spatie/example",
            path: layout.worktree, branch: "feature/queue", baseBranch: "main"
        )
        let runtime = WorkspaceRuntime(store: store, workspaceID: workspace.id, makeRunner: { _, _, _, _, _ in NeverRunner() },
                                       installedAgents: { [.claudeCode] }, models: { _ in [] })
        try await runtime.start()
        let steps = Steps()
        await runtime.observeActivity { event in
            switch event {
            case .setupStarted(let step), .setupStep(let step): steps.add(step)
            case .setupFinished(let succeeded): steps.add(succeeded ? "finished" : "failed")
            default: break
            }
        }
        let services = ServiceSupervisor(layout: layout, tuning: .init(stopGrace: .seconds(2)))
        return Fixture(root: root, origin: origin, layout: layout, store: store, runtime: runtime, services: services,
                       steps: steps, orderFile: root + "/order", gitConfig: root + "/gitconfig")
    }

    static let settings = """
    [scripts]
    prepare = "echo prepare >> \\"$ORDER_FILE\\""
    setup_file = ".bloom/setup.sh"
    resume = "echo resume >> \\"$ORDER_FILE\\""
    """

    static let setupScript = """
    #!/bin/bash
    echo setup >> "$ORDER_FILE"
    echo "setup says hello"
    echo "url=$BLOOM_PUBLIC_URL host=$BLOOM_PUBLIC_HOST port=$BLOOM_APP_PORT id=$BLOOM_WORKSPACE_ID branch=$BLOOM_BRANCH repo=$BLOOM_REPOSITORY team=$TEAM_VALUE" > "$ORDER_FILE.env"
    command -v gh >> "$ORDER_FILE.env"
    """

    @Test("the whole sequence clones, checks the branch out, runs every script in order and records it all")
    func wholeSequence() async throws {
        let fixture = try await fixture(files: [".bloom/settings.toml": Self.settings, ".bloom/setup.sh": Self.setupScript], executables: [".bloom/setup.sh"])
        let setup = try fixture.setup()

        await setup.run()

        #expect(fixture.order == ["prepare", "setup", "resume"])
        #expect(fixture.steps.all == ["environment", "git", "clone", "prepare", "setup", "resume", "finished"])
        let branch = try SetupTestSupport.bash("git rev-parse --abbrev-ref HEAD", in: fixture.worktree)
        #expect(branch.trimmingCharacters(in: .whitespacesAndNewlines) == "feature/queue")
        let base = try SetupTestSupport.bash("git rev-parse HEAD origin/main", in: fixture.worktree).split(separator: "\n")
        #expect(base.count == 2 && base[0] == base[1])
        // Started from the base, but not tracking it, so a push cannot land on main.
        #expect((try? SetupTestSupport.bash("git rev-parse --abbrev-ref @{upstream}", in: fixture.worktree)) == nil)

        let workspace = try await fixture.workspace()
        #expect(workspace.setupState == .succeeded)
        #expect(workspace.setupLog.contains("setup says hello"))
        #expect(workspace.setupLog.contains("[bloom] Running the setup script."))
        #expect(SetupTestSupport.read(fixture.layout.dataDirectory + "/setup/setup.log").contains("setup says hello"))
        #expect(try await fixture.store.setting(MachineSetup.completedSetting) == "1")

        let environment = SetupTestSupport.read(fixture.orderFile + ".env")
        #expect(environment.contains(
            "url=https://bloom-test.sprites.app host=bloom-test.sprites.app port=3017 id=01k5bx7j9d3v2r8q6m4n0p1s2w branch=feature/queue repo=spatie/example team=from the team"
        ))
        #expect(environment.contains(setup.binDirectory + "/gh"))

        let gitConfig = SetupTestSupport.read(fixture.gitConfig)
        #expect(gitConfig.contains("fake-bloom-runner' git-credential"))
        #expect(gitConfig.contains("useHttpPath = true"))
        #expect(FileManager.default.isExecutableFile(atPath: setup.binDirectory + "/gh"))
        await fixture.runtime.shutdown()
    }

    @Test("a branch that exists on the remote is checked out as it is there")
    func existingBranch() async throws {
        let fixture = try await fixture(
            files: ["README.md": "main\n"], originBranches: ["feature/queue": ["README.md": "the branch\n"]]
        )
        try await fixture.setup().run()

        #expect(SetupTestSupport.read(fixture.worktree + "/README.md") == "the branch\n")
        let upstream = try SetupTestSupport.bash("git rev-parse --abbrev-ref @{upstream}", in: fixture.worktree)
        #expect(upstream.trimmingCharacters(in: .whitespacesAndNewlines) == "origin/feature/queue")
        // No scripts, and a clone is still a step.
        #expect(fixture.steps.all == ["environment", "git", "clone", "finished"])
        #expect(try await fixture.workspace().setupState == .succeeded)
        await fixture.runtime.shutdown()
    }

    /// **The phase before any work used to be invisible**, so a brand new workspace said pending
    /// with no step through a call to runbloom.app and the whole git configuration, which is where
    /// the one measured hang sat. It is two steps now, and they are the first thing anybody sees.
    @Test("the first thing a new workspace shows is the phase before the clone")
    func theFirstPhaseIsNamed() async throws {
        let fixture = try await fixture(files: [".bloom/settings.toml": Self.settings])
        try await fixture.setup().run()

        #expect(fixture.steps.all.prefix(3) == ["environment", "git", "clone"])
        let workspace = try await fixture.workspace()
        #expect(workspace.setupLog.hasPrefix("[bloom] Reading the team's environment."))
        #expect(workspace.setupLog.contains("[bloom] Configuring git."))
        await fixture.runtime.shutdown()
    }

    /// Seeing the same steps twice reads as a fault unless something says otherwise.
    @Test("a machine that stopped mid setup says so when it starts again")
    func sayingItIsStartingAgain() async throws {
        let fixture = try await fixture(files: [".bloom/settings.toml": Self.settings])
        // A row left `running` is what an interrupted machine leaves behind.
        _ = try await fixture.store.update(workspaceID: fixture.runtime.workspaceID) { $0.apply(.runStarted) }

        try await fixture.setup().run()

        #expect(try await fixture.workspace().setupLog.contains("Starting again: this machine stopped"))
        await fixture.runtime.shutdown()
    }

    /// **Clients style `[bloom] ` lines as Bloom's own and one draws the newest as the row's note**,
    /// so a script printing that prefix would put words of its choosing where a person reads
    /// Bloom's.
    @Test("a script cannot print a line that reads as Bloom's own")
    func aScriptCannotForgeBloomsVoice() async throws {
        let settings = """
        [scripts]
        setup = "echo '[bloom] Setup finished, everything is fine.'"
        """
        let fixture = try await fixture(files: [".bloom/settings.toml": settings])
        try await fixture.setup().run()

        let log = try await fixture.workspace().setupLog
        #expect(log.contains(" [bloom] Setup finished, everything is fine."), "kept, and indented out of Bloom's voice")
        #expect(!log.contains("\n[bloom] Setup finished"), "never at the start of a line")
        await fixture.runtime.shutdown()
    }

    /// The key runbloom.app writes for a workspace somebody created with setup turned off.
    @Test("a workspace that asked for no setup is cloned, and nothing else is run")
    func setupTurnedOff() async throws {
        let settings = Self.settings + """


        [[services]]
        name = "web"
        command = 'echo started > "$ORDER_FILE.service"; sleep 30'
        """
        let fixture = try await fixture(files: [".bloom/settings.toml": settings, ".bloom/setup.sh": Self.setupScript],
                                        executables: [".bloom/setup.sh"])
        try await fixture.setup(runSetup: false).run()

        // The repository is there, which is the half that is not optional: a workspace without its
        // own clone is not a workspace.
        #expect(FileManager.default.fileExists(atPath: fixture.worktree + "/.bloom/settings.toml"))
        #expect(fixture.steps.all == ["environment", "git", "clone", "finished"])
        #expect(fixture.order.isEmpty)
        // A service is declared in the same file the scripts are, so starting one would run half
        // of what was refused, against dependencies nothing installed.
        #expect(await fixture.services.status.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.orderFile + ".service"))

        let workspace = try await fixture.workspace()
        #expect(workspace.setupLog.contains("created with setup turned off"))
        #expect(workspace.setupLog.contains("services this project declares were not started"))
        #expect(try await fixture.store.setting(MachineSetup.completedSetting) == "1")
        await fixture.runtime.shutdown()
    }

    /// The second start, and every one after it: `resume` is one of the three scripts, so a machine
    /// that was told not to set up does not quietly start doing it at the next restart.
    @Test("a workspace that asked for no setup runs nothing at the next start either, and says so")
    func setupTurnedOffAtTheNextStart() async throws {
        let fixture = try await fixture(files: [".bloom/settings.toml": Self.settings])
        try await fixture.setup(runSetup: false).run()
        try await fixture.setup(runSetup: false).run()

        #expect(fixture.order.isEmpty)
        let workspace = try await fixture.workspace()
        #expect(workspace.setupState == .skipped)
        #expect(workspace.setupLog.contains("created with setup turned off"))
        await fixture.runtime.shutdown()
    }

    /// The one machine in the middle: created with setup turned off, set up anyway by a runner
    /// older than the key, and then updated to one that reads it. Its services are somebody's
    /// working preview and its log is the account of a setup that really happened.
    @Test("a machine that already set up is left alone when its server learns setup was off")
    func setupRanBeforeTheKeyWasUnderstood() async throws {
        let fixture = try await fixture(files: [".bloom/settings.toml": Self.settings])
        // The old runner: the key is not in its configuration at all, so it sets up.
        try await fixture.setup().run()
        #expect(fixture.order == ["prepare", "resume"])
        // Every trace an older runner leaves behind, which is a completed sequence and no record
        // of having skipped anything.
        try await fixture.store.setSetting(MachineSetup.skippedSetting, nil)

        try await fixture.setup(runSetup: false).run()

        #expect(fixture.order == ["prepare", "resume", "resume"])
        let workspace = try await fixture.workspace()
        #expect(workspace.setupState == .succeeded)
        #expect(workspace.setupLog.contains("set up anyway before this machine's server understood"))
        #expect(!workspace.setupLog.contains("nothing else was run"))
        await fixture.runtime.shutdown()
    }

    /// The reader never assumes the writer wrote it. Every machine bootstrapped before the key
    /// existed has a `workspace.json` without it, and setting up is what those machines do.
    @Test("a configuration written before the key existed still sets up")
    func setupWhenTheKeyIsAbsent() async throws {
        let fixture = try await fixture(files: [".bloom/settings.toml": Self.settings])
        try await fixture.setup().run()

        #expect(fixture.order == ["prepare", "resume"])
        #expect(try await fixture.workspace().setupState == .succeeded)
        await fixture.runtime.shutdown()
    }

    @Test("a failing step stops the sequence, keeps its output and leaves setup to run again")
    func failingStep() async throws {
        let settings = """
        [scripts]
        setup = "echo broken on purpose; exit 3"
        resume = "echo resume >> \\"$ORDER_FILE\\""

        [[services]]
        name = "web"
        command = "echo started > \\"$ORDER_FILE.service\\"; sleep 30"
        """
        let fixture = try await fixture(files: [".bloom/settings.toml": settings])
        try await fixture.setup().run()

        #expect(fixture.steps.all == ["environment", "git", "clone", "setup", "failed"])
        #expect(fixture.order.isEmpty)
        let workspace = try await fixture.workspace()
        #expect(workspace.setupState == .failed)
        #expect(workspace.setupLog.contains("broken on purpose"))
        #expect(workspace.setupLog.contains("The setup script exited with status 3."))
        #expect(try await fixture.store.setting(MachineSetup.completedSetting) == nil)
        #expect(await fixture.services.status.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.orderFile + ".service"))
        await fixture.runtime.shutdown()
    }

    @Test("a run the machine was stopped in the middle of is added to, not started over")
    func aSecondRunKeepsTheFirstOutput() async throws {
        let settings = """
        [scripts]
        setup = "echo second attempt"
        """
        let fixture = try await fixture(files: [".bloom/settings.toml": settings])
        // What a machine stopped mid setup leaves behind: the row still running, with its output.
        _ = try await fixture.store.update(workspaceID: fixture.runtime.workspaceID) { workspace in
            workspace.apply(.runStarted)
            workspace.apply(.runProgressed(log: "[bloom] Cloning the repository.\nfirst attempt"))
        }
        try await fixture.setup().run()

        let workspace = try await fixture.workspace()
        #expect(workspace.setupState == .succeeded)
        #expect(workspace.setupLog.contains("first attempt"), "The interrupted run's output is kept")
        #expect(workspace.setupLog.contains("second attempt"))
        await fixture.runtime.shutdown()
    }

    @Test("a clone that fails says what to check, and the next start clones again")
    func cloneFailureExplainsItself() async throws {
        let fixture = try await fixture(files: ["README.md": "example"])
        let setup = try fixture.setup(origin: "/nowhere/not-a-repository.git")
        await setup.runWholeSequence()

        let workspace = try await fixture.workspace()
        #expect(workspace.setupState == .failed)
        #expect(workspace.setupLog.contains("spatie/example could not be cloned"))
        #expect(workspace.setupLog.contains("GitHub App is installed for it"))
        #expect(try await fixture.store.setting(MachineSetup.clonedSetting) == nil, "A half-made clone is not taken for a whole one")
        await fixture.runtime.shutdown()
    }

    @Test("a project with no Cloud setup is told so, in words, and its Mac setup script still runs")
    func noCloudSetupIsExplained() async throws {
        // What a repository looks like before its Cloud workspace pull request lands: a Conductor
        // settings file with a setup script written for a Mac, and nothing else.
        let settings = """
        [scripts]
        setup = "set -u; echo \\"root is $BLOOM_ROOT_PATH\\"; echo \\"project is $BLOOM_PROJECT_NAME\\""
        """
        let fixture = try await fixture(files: [".conductor/settings.toml": settings])
        try await fixture.setup().run()

        let workspace = try await fixture.workspace()
        #expect(workspace.setupLog.contains("This project has no Bloom Cloud workspace setup yet"))
        #expect(workspace.setupLog.contains(".bloom/settings.toml"))
        #expect(workspace.setupLog.contains("may not work on a machine"))
        // The variables a Mac script reads are set, so `set -u` does not end it on the first line.
        #expect(workspace.setupState == .succeeded)
        #expect(workspace.setupLog.contains("root is \(fixture.worktree)"))
        #expect(workspace.setupLog.contains("project is example"))
        await fixture.runtime.shutdown()
    }

    @Test("a project with a .bloom settings file is not told anything about setting one up")
    func cloudSetupIsNotExplained() async throws {
        let fixture = try await fixture(files: [".bloom/settings.toml": Self.settings])
        try await fixture.setup().run()
        #expect(try await !fixture.workspace().setupLog.contains("no Bloom Cloud workspace setup"))
        await fixture.runtime.shutdown()
    }

    @Test("a step that stops moving says so, rather than leaving a machine that looks alive")
    func aStalledStepSaysSo() async throws {
        let settings = """
        [scripts]
        prepare = "sleep 4"
        """
        let fixture = try await fixture(files: [".bloom/settings.toml": settings])
        // Two seconds rather than five minutes, which is the only thing the real machine changes.
        let setup = try fixture.setup(stallAfter: 2)

        await setup.run()

        let workspace = try await fixture.workspace()
        #expect(workspace.setupLog.contains("Setup has been in prepare for"), "\(workspace.setupLog.suffix(400))")
        // **What it says next is the verdict's, and the verdict is only readable where `/proc` is.**
        // On a machine, `sleep 4` is alive and the sentence says so and advises nothing; on a Mac
        // there is nothing to read, and the advice is given because not knowing and knowing nothing
        // is alive are answered the same way. Asserting one wording here would have been asserting
        // which platform the suite runs on, and the Linux job said so within the hour.
        let sentence = workspace.setupLog
        #if os(Linux)
        #expect(sentence.contains("still working") || sentence.contains("waiting on something"))
        #expect(!sentence.contains("restarting this machine's server"), "nothing needs restarting while it runs")
        #else
        #expect(sentence.contains("restarting this machine's server clears it"))
        #endif
        // The step finished on its own, so the sentence is a warning rather than a verdict.
        #expect(workspace.setupState == .succeeded)
    }

    @Test("a step that is printing is working, whatever its own clock says")
    func outputIsProgress() async throws {
        let settings = """
        [scripts]
        prepare = "for i in 1 2 3 4 5 6 7 8; do echo working $i; sleep 0.5; done"
        """
        let fixture = try await fixture(files: [".bloom/settings.toml": settings])
        let setup = try fixture.setup(stallAfter: 2)

        await setup.run()

        let workspace = try await fixture.workspace()
        #expect(workspace.setupLog.contains("working 8"))
        #expect(!workspace.setupLog.contains("with nothing new"), "a printing script is not a stall")
    }

    @Test("a failed step says which script it was")
    func failureNamesTheScript() async throws {
        let settings = """
        [scripts]
        setup = "echo about to fail; exit 4"
        """
        let fixture = try await fixture(files: [".bloom/settings.toml": settings])
        try await fixture.setup().run()
        let log = try await fixture.workspace().setupLog
        #expect(log.contains("about to fail"))
        #expect(log.contains("The setup script exited with status 4."))
        await fixture.runtime.shutdown()
    }

    @Test("a later start runs only resume, and then the services")
    func resumeOnly() async throws {
        let settings = Self.settings + """


        [[services]]
        name = "web"
        command = "echo \\"$TEAM_VALUE\\" > \\"$ORDER_FILE.service\\"; exec sleep 30"
        """
        let fixture = try await fixture(files: [".bloom/settings.toml": settings, ".bloom/setup.sh": Self.setupScript], executables: [".bloom/setup.sh"])
        try await fixture.setup().run()
        #expect(fixture.order == ["prepare", "setup", "resume"])
        #expect(await SetupTestSupport.eventually { SetupTestSupport.read(fixture.orderFile + ".service") == "from the team\n" })
        await fixture.services.stopAll()

        // A new server process: a new setup over the same store and disk.
        try await fixture.setup().run()

        #expect(fixture.order == ["prepare", "setup", "resume", "resume"])
        #expect(fixture.steps.all == ["environment", "git", "clone", "prepare", "setup", "resume", "services", "finished", "resume", "services", "finished"])
        let workspace = try await fixture.workspace()
        #expect(workspace.setupState == .succeeded)
        // The first setup's account stays, with the resume after it, and the services it started
        // last: the log ends where the machine's work does rather than where its scripts do.
        #expect(workspace.setupLog.contains("setup says hello"))
        #expect(workspace.setupLog.contains("[bloom] Running the resume script."))
        #expect(workspace.setupLog.hasSuffix("[bloom] Started 1 service. Whether each is ready is on the workspace itself.\n"))
        #expect(await SetupTestSupport.eventually { await fixture.services.status.first?.state == .running })
        await fixture.services.stopAll()
        await fixture.runtime.shutdown()
    }

    @Test("a script that outlives its timeout is stopped and fails the step")
    func timeout() async throws {
        let settings = """
        [scripts]
        prepare = "echo waiting; sleep 30"
        setup = "echo setup >> \\"$ORDER_FILE\\""
        """
        let fixture = try await fixture(files: [".bloom/settings.toml": settings])
        let started = ContinuousClock.now
        try await fixture.setup(timeouts: .init(clone: .seconds(60), prepare: .seconds(1), setup: .seconds(60), resume: .seconds(60))).run()

        #expect(ContinuousClock.now - started < .seconds(20))
        #expect(fixture.order.isEmpty)
        let workspace = try await fixture.workspace()
        #expect(workspace.setupState == .failed)
        #expect(workspace.setupLog.contains("took longer than 1 second"))
        await fixture.runtime.shutdown()
    }

    @Test("a missing script file is noted and skipped rather than failing setup")
    func missingScriptFile() async throws {
        let settings = """
        [scripts]
        prepare_file = ".bloom/not-committed.sh"
        resume = "echo resume >> \\"$ORDER_FILE\\""
        """
        let fixture = try await fixture(files: [".bloom/settings.toml": settings])
        try await fixture.setup().run()

        #expect(fixture.order == ["resume"])
        #expect(fixture.steps.all == ["environment", "git", "clone", "resume", "finished"])
        let workspace = try await fixture.workspace()
        #expect(workspace.setupState == .succeeded)
        #expect(workspace.setupLog.contains("names .bloom/not-committed.sh as the prepare script"))
        await fixture.runtime.shutdown()
    }

    @Test("output reaches the setup log while the step is still running")
    func liveOutput() async throws {
        // The script waits for a file the test creates rather than for a fixed time, so a slow
        // runner cannot let it finish before the test has looked.
        let release = NSTemporaryDirectory() + "bloom-live-output-\(UUID().uuidString)"
        let settings = """
        [scripts]
        setup = "echo first line; for i in $(seq 1 600); do [ -e '\(release)' ] && break; sleep 0.1; done; echo second line"
        """
        let fixture = try await fixture(files: [".bloom/settings.toml": settings])
        let setup = try fixture.setup()
        let run = Task { await setup.run() }

        let sawFirst = await SetupTestSupport.eventually(timeout: .seconds(15)) {
            guard let workspace = try? await fixture.store.workspace(id: fixture.runtime.workspaceID) else { return false }
            return workspace.setupLog.contains("first line")
        }
        #expect(sawFirst)
        let midway = try await fixture.workspace()
        #expect(midway.setupState == .running)
        #expect(!midway.setupLog.contains("second line"))
        _ = FileManager.default.createFile(atPath: release, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: release) }
        await run.value
        #expect(try await fixture.workspace().setupLog.contains("second line"))
        await fixture.runtime.shutdown()
    }

    @Test("the gh wrapper runs the real gh with a token from bloom-runner")
    func ghWrapper() throws {
        let root = try SetupTestSupport.directory("gh-wrapper")
        let tools = MachineGitTools(serverExecutable: root + "/bloom server", dataDirectory: root + "/data", serverPort: 8081, repository: "spatie/example")
        try tools.writeGhWrapper()
        try SetupTestSupport.write("""
        #!/bin/sh
        echo "token-for-$BLOOM_REPOSITORY-$1-$BLOOM_DATA_DIR"
        """, to: root + "/bloom server", executable: true)
        try SetupTestSupport.write("""
        #!/bin/sh
        echo "gh $* with $GH_TOKEN"
        """, to: root + "/real/gh", executable: true)

        let output = try SetupTestSupport.bash("gh pr list --json", environment: ["PATH": "\(tools.binDirectory):\(root)/real:/usr/bin:/bin"])
        #expect(output == "gh pr list --json with token-for-spatie/example-gh-token-\(root)/data\n")

        let missing = try? SetupTestSupport.bash("gh --version", environment: ["PATH": "\(tools.binDirectory):/usr/bin:/bin"])
        #expect(missing == nil)
    }
}
