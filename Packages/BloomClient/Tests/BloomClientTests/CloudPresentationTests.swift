@testable import BloomClient
import BloomProtocol
import Foundation
import Testing

@Suite struct CloudWorkspaceNoticesTests {
    private func item(_ id: String, _ state: String, role: String? = "owner", excerpt: String? = nil) -> CloudWorkspaceItem {
        CloudWorkspaceItem(id: id, teamID: "t", name: "Workspace \(id)", branch: "b", state: state, role: role,
                           summary: excerpt.map { CloudWorkspaceSummary(lastMessage: .init(excerpt: $0)) })
    }

    @Test func theFirstReadingSaysNothing() {
        #expect(CloudWorkspaceNotices.between(previous: nil, current: [item("a", "waiting_for_input")]).isEmpty)
    }

    @Test func transitionsIntoWaitingFinishedAndFailedAreReported() {
        let before = [item("a", "running"), item("b", "running"), item("c", "setting_up"), item("d", "idle")]
        let after = [item("a", "waiting_for_input", excerpt: "Should it retry?"), item("b", "idle"), item("c", "setup_failed"), item("d", "idle")]
        let notices = CloudWorkspaceNotices.between(previous: before, current: after)
        #expect(notices.map(\.kind) == [.needsInput, .finished, .setupFailed])
        #expect(notices.first?.detail == "Should it retry?")
    }

    @Test func idleWithoutHavingRunIsNotAFinishedTurn() {
        #expect(CloudWorkspaceNotices.between(previous: [item("a", "setting_up")], current: [item("a", "idle")]).isEmpty)
    }

    @Test func workspacesTheReaderIsNotInAndNewOnesAreQuiet() {
        let notices = CloudWorkspaceNotices.between(
            previous: [item("a", "running", role: nil)],
            current: [item("a", "waiting_for_input", role: nil), item("new", "setup_failed")]
        )
        #expect(notices.isEmpty)
    }

    @Test func aWorkspaceCreatedHereIsWatchedFromItsFirstReading() {
        let notices = CloudWorkspaceNotices.between(previous: [], current: [item("new", "setup_failed")], watching: ["new"])
        #expect(notices.map(\.kind) == [.setupFailed])
    }
}

@Suite struct CloudWorkspaceStatusTests {
    @Test func anIdleWorkspaceIsAsleepOrReadyByItsMachine() {
        let asleep = CloudWorkspaceItem(id: "a", teamID: "t", name: "n", branch: "b", state: "idle", summary: CloudWorkspaceSummary(awake: false))
        let awake = CloudWorkspaceItem(id: "a", teamID: "t", name: "n", branch: "b", state: "idle", summary: CloudWorkspaceSummary(awake: true))
        #expect(CloudWorkspaceStatus(item: asleep) == .asleep)
        #expect(CloudWorkspaceStatus(item: awake) == .idle)
    }

    @Test func setupSaysWhichStep() {
        let item = CloudWorkspaceItem(id: "a", teamID: "t", name: "n", branch: "b", state: "setting_up",
                                      summary: CloudWorkspaceSummary(setup: .init(state: "running", step: "prepare")))
        #expect(CloudWorkspaceStatus(item: item).phrase == "Setting up: preparing")
    }
}

@Suite struct PendingOpeningPromptTests {
    private let controls = ComposerControlsRecord(agent: "claude", model: "claude-opus-5", effort: "high", permissionMode: "acceptEdits", interactionMode: "build")

    @Test func opensAChatFirstThenSendsIntoIt() {
        var prompt = PendingOpeningPrompt(workspaceID: "w", text: "Fix the queue", controls: controls)
        let first = prompt.nextOperation
        #expect(first.operation == .newChat(controls: controls))
        #expect(first.commandID == prompt.chatCommandID)
        prompt.chatID = "c1"
        #expect(prompt.nextOperation.operation == .send(chatID: "c1", text: "Fix the queue"))
        #expect(prompt.nextOperation.commandID == prompt.sendCommandID)
    }

    @Test func survivesBeingWrittenAndDropsStaleOnes() {
        let now = Date()
        let fresh = PendingOpeningPrompt(workspaceID: "w1", text: "a", controls: controls, createdAt: now)
        let stale = PendingOpeningPrompt(workspaceID: "w2", text: "b", controls: controls, createdAt: now.addingTimeInterval(-2 * 24 * 60 * 60))
        let stored = PendingOpeningPrompts(prompts: ["w1": fresh, "w2": stale]).encoded
        let read = PendingOpeningPrompts.decode(stored, now: now)
        #expect(read.prompts.keys.sorted() == ["w1"])
        #expect(read.prompts["w1"]?.sendCommandID == fresh.sendCommandID)
    }
}

@Suite struct CloudBranchNameTests {
    @Test(arguments: ["freek/queue-retries", "fix-123", "a.b/c"])
    func goodNamesPass(name: String) {
        #expect(CloudBranchName.problem(name) == nil)
    }

    @Test(arguments: ["", "-x", "a..b", "a b", "a~b", "x.lock", "a/", "a//b", "a/.b", "a@{b", "x."])
    func badNamesSayWhy(name: String) {
        #expect(CloudBranchName.problem(name) != nil)
    }

    @Test func aSuggestionIsASlugUnderThePrefix() {
        #expect(CloudBranchName.suggestion(for: "Queue retries, again!", prefix: "freek") == "freek/queue-retries-again")
        #expect(CloudBranchName.suggestion(for: "   ", prefix: "freek") == "")
    }
}

@Suite struct CloudConnectionBannerTests {
    @Test func nothingIsSaidWhileAConnectionIsQuickOrLive() {
        #expect(CloudConnectionBanner.of(.connecting(waking: false)) == nil)
        #expect(CloudConnectionBanner.of(.live) == nil)
    }

    @Test func wakingIsSaidInWords() {
        let banner = CloudConnectionBanner.of(.connecting(waking: true))
        #expect(banner?.tone == .progress)
        #expect(banner?.title.contains("Waking") == true)
    }

    @Test func aLimitThatClearsByItselfOffersNoButton() {
        let waiting = CloudConnectionBanner.of(.limited(LimitNotice(limit: "concurrent_machines", message: "Twenty running.")))
        #expect(waiting?.tone == .caution)
        #expect(waiting?.actions.isEmpty == true)
        let blocked = CloudConnectionBanner.of(.limited(LimitNotice(limit: "kill_switch", message: "Paused.")))
        #expect(blocked?.tone == .failure)
        #expect(blocked?.title == "Paused.")
        #expect(blocked?.actions == [.runbloom, .retry])
    }

    /// Every state a first Cloud workspace passes through offers something, or is a state that
    /// finishes by itself.
    @Test func everyStateThatNeedsSomebodyOffersAWayForward() {
        let needSomebody: [WorkspaceConnection.Phase] = [
            .asleep, .noAccess("Removed."), .retrying("This Mac is offline."),
            .limited(LimitNotice(limit: "monthly_usage", message: "Over budget.")),
        ]
        for phase in needSomebody {
            #expect(CloudConnectionBanner.of(phase)?.actions.isEmpty == false, "\(phase) offers nothing")
        }
        // These carry on by themselves, and say so rather than offering a button that repeats them.
        #expect(CloudConnectionBanner.of(.connecting(waking: true))?.actions.isEmpty == true)
        #expect(CloudConnectionBanner.of(.limited(LimitNotice(limit: "concurrent_machines", message: "Wait.")))?.actions.isEmpty == true)
    }

    @Test func aMachineThatIsNotReadyOffersTheSetupOutput() {
        #expect(CloudConnectionBanner.of(.notReady(message: "Still starting.", retryAfter: 5))?.actions == [.watchSetup])
    }


    @Test func noUserFacingWordNamesTheProvider() {
        let phases: [WorkspaceConnection.Phase] = [
            .connecting(waking: true), .asleep, .notReady(message: "x", retryAfter: 1), .archived, .noAccess("x"), .retrying("x"),
            .limited(LimitNotice(limit: "monthly_usage", message: "x")),
        ]
        for phase in phases {
            let banner = CloudConnectionBanner.of(phase)
            let words = ([banner?.title, banner?.message].compactMap { $0 } + (banner?.actions ?? []).map(\.title))
                .joined(separator: " ").lowercased()
            #expect(!words.contains("sprite") && !words.contains("fly") && !words.contains("remote") && !words.contains("machine") && !words.contains("runner"))
        }
    }
}

@Suite struct CloudArchiveConfirmationTests {
    @Test func theConversationIsAlwaysSaidFirst() {
        let clean = ArchivePreviewRecord(confirmationID: "c", hasUncommittedChanges: false, untrackedFiles: [], unpushedCommits: 0, detachedCommits: 0,
                                         isAgentRunning: false, isPullRequestMerged: true, createdAt: Date())
        let confirmation = CloudArchiveConfirmation(preview: clean)
        #expect(confirmation.losses == [CloudArchiveConfirmation.conversationSentence])
        #expect(!confirmation.isDestructive)
        #expect(confirmation.confirmationID == "c")
    }

    @Test func everyHazardIsNamed() {
        let risky = ArchivePreviewRecord(confirmationID: "c", hasUncommittedChanges: true, untrackedFiles: ["a.txt"], unpushedCommits: 2, detachedCommits: 1,
                                         isAgentRunning: true, isPullRequestMerged: false, createdAt: Date())
        let confirmation = CloudArchiveConfirmation(preview: risky)
        #expect(confirmation.losses.count == 6)
        #expect(confirmation.isDestructive)
        #expect(confirmation.losses.contains("2 commits have not been pushed."))
    }

    @Test func withoutTheMachineTheSummarySpeaks() {
        let confirmation = CloudArchiveConfirmation(summary: CloudWorkspaceSummary(diff: .init(files: 3, additions: 1, deletions: 1)))
        #expect(confirmation.confirmationID == nil)
        #expect(confirmation.losses.first == CloudArchiveConfirmation.conversationSentence)
        #expect(confirmation.losses.last?.contains("3 files") == true)
    }
}

@Suite struct TerminalSocketTests {
    @Test func theAddressIsASecureSocketWithTheNameAndNoToken() {
        let url = TerminalSocket.url(machine: URL(string: "https://bloom-x.sprites.test")!, name: "shell-01k5")
        #expect(url.absoluteString == "wss://bloom-x.sprites.test/_bloom/v1/terminal?name=shell-01k5")
    }

    @Test func framesAreSpelledTheWireWay() {
        #expect(TerminalSocket.text(.auth(token: "t")) == #"{"kind":"auth","token":"t"}"#)
        #expect(TerminalSocket.text(.resize(columns: 120, rows: 40)) == #"{"columns":120,"kind":"resize","rows":40}"#)
    }

    @Test func everyPersonGetsAShellOfTheirOwn() {
        #expect(TerminalSocket.name(for: "01K5ABCDEF") == "shell-01k5abcdef")
        #expect(TerminalSocket.name(for: nil) == "shell")
        #expect(TerminalSocket.name(for: "a/b c") == "shell-abc")
    }
}

@Suite struct CloudReviewCacheTests {
    private func file(_ path: String, revision: String) -> ChangedFileRecord {
        ChangedFileRecord(path: path, change: "modified", additions: 1, deletions: 0, isBinary: false, contentRevision: revision)
    }

    @Test func aSnapshotWithoutFilesKeepsWhatWasHeld() {
        var cache = CloudReviewCache()
        cache.absorb(ReviewSnapshotRecord(revision: "r1", files: [file("a", revision: "1")]))
        cache.absorb(ReviewSnapshotRecord(revision: "r1", files: nil))
        #expect(cache.files.map(\.path) == ["a"])
        #expect(cache.revision == "r1")
    }

    @Test func aPatchIsKeptUntilItsFileMoves() {
        var cache = CloudReviewCache()
        cache.absorb(ReviewSnapshotRecord(revision: "r1", files: [file("a", revision: "1")]))
        #expect(cache.knownRevision(for: "a") == nil)
        cache.absorb(PatchSnapshotRecord(revision: "1", patch: "+x"), for: "a")
        #expect(cache.knownRevision(for: "a") == "1")
        #expect(cache.absorb(PatchSnapshotRecord(revision: "1", patch: nil), for: "a") == "+x")
        cache.absorb(ReviewSnapshotRecord(revision: "r2", files: [file("a", revision: "2")]))
        #expect(cache.knownRevision(for: "a") == nil)
        #expect(cache.patch(for: "a") == nil)
    }
}

@Suite struct AddressSafetyTests {
    @Test func aTokenGoesOnlyToASecureMachine() {
        #expect(SessionToken.isSafe(URL(string: "https://bloom-x.sprites.test")!))
        #expect(SessionToken.isSafe(URL(string: "http://localhost:8080")!))
        #expect(!SessionToken.isSafe(URL(string: "http://bloom-x.sprites.test")!))
        #expect(!SessionToken.isSafe(URL(string: "https://user:pass@bloom-x.sprites.test")!))
        #expect(!SessionToken.isSafe(URL(string: "file:///etc/passwd")!))
    }

    @Test func aPreviewOpensOnlyOnItsOwnMachine() {
        let machine = URL(string: "https://bloom-x.sprites.test")!
        let good = PreviewToken(token: "p", expiresAt: Date(), enterURL: URL(string: "https://bloom-x.sprites.test/_bloom/preview/enter?token=p")!)
        let elsewhere = PreviewToken(token: "p", expiresAt: Date(), enterURL: URL(string: "https://evil.test/_bloom/preview/enter?token=p")!)
        let scheme = PreviewToken(token: "p", expiresAt: Date(), enterURL: URL(string: "bloom://oauth/callback?code=x")!)
        #expect(good.isSafe(forMachine: machine))
        #expect(!elsewhere.isSafe(forMachine: machine))
        #expect(!scheme.isSafe(forMachine: nil))
    }

    @Test func aConnectionRefusesAnInsecureMachine() async {
        let transport = FakeTransport()
        transport.on("POST", "/session-token", .json(Fixtures.sessionToken().replacingOccurrences(of: "https://", with: "http://")))
        let connection = WorkspaceConnection(workspaceID: "w", api: Fixtures.api(transport), machine: MachineClient(transport: transport))
        do {
            _ = try await connection.perform(.workspace)
            Issue.record("Expected a refusal")
        } catch {
            #expect(error == .runbloom(SessionToken.unsafeMachineURL))
        }
        #expect(transport.requests(to: "/_bloom/v1/rpc").isEmpty)
    }
}

@Suite struct TeamSetupTests {
    private let environment = RunbloomEnvironment(origin: RunbloomEnvironment.productionOrigin, urlScheme: "bloomcloud")

    private func team(_ json: String) throws -> RunbloomTeam {
        try JSONDecoder().decode(RunbloomTeam.self, from: Data(json.utf8))
    }

    @Test func aTeamInEarlyAccessWithStepsLeftSaysWhichAndWhere() throws {
        let team = try team("""
        {"id": "t", "name": "Spatie", "role": "owner", "cloud_workspaces_enabled": true,
         "setup": {"enabled": true, "github_connected": true, "github_app_installed": false, "has_project": false, "has_agent_key": true,
                   "setup_url": "https://runbloom.app/teams/t/dashboard"}}
        """)
        #expect(!team.isReadyForCloudWorkspaces)
        let notice = try #require(TeamSetupNotice(team: team, environment: environment))
        #expect(notice.steps == ["Install the Bloom GitHub App for the team.", "Add a repository as a project."])
        #expect(notice.setupPage?.absoluteString == "https://runbloom.app/teams/t/dashboard")
    }

    @Test func aTeamNotInEarlyAccessSaysSo() throws {
        let team = try team(#"{"id": "t", "name": "Side", "cloud_workspaces_enabled": false, "setup": {"enabled": false}}"#)
        let notice = try #require(TeamSetupNotice(team: team, environment: environment))
        #expect(notice.sentence.contains("early access"))
        #expect(notice.steps.isEmpty)
    }

    @Test func fieldsBesideTheTeamAreReadToo() throws {
        let team = try team(#"{"id": "t", "name": "Flat", "enabled": true, "has_agent_key": false, "setup_url": "https://runbloom.app/teams/t"}"#)
        #expect(team.cloudWorkspacesEnabled)
        #expect(team.setup?.missing == ["Add a Claude Code or Codex API key."])
    }

    @Test func aReadyTeamOrOneThatSaysNothingHasNoNotice() throws {
        let ready = try team(#"{"id": "t", "name": "Ready", "cloud_workspaces_enabled": true, "setup": {"enabled": true, "github_connected": true, "github_app_installed": true, "has_project": true, "has_agent_key": true}}"#)
        #expect(TeamSetupNotice(team: ready, environment: environment) == nil)
        let silent = try team(#"{"id": "t", "name": "Old", "cloud_workspaces_enabled": true}"#)
        #expect(silent.setup == nil)
        #expect(TeamSetupNotice(team: silent, environment: environment) == nil)
    }

    @Test func aSetupPageElsewhereIsNotOffered() throws {
        let team = try team(#"{"id": "t", "name": "X", "cloud_workspaces_enabled": true, "setup": {"has_project": false, "setup_url": "https://evil.test/setup"}}"#)
        #expect(TeamSetupNotice(team: team, environment: environment)?.setupPage == nil)
    }
}

@Suite struct CloudSetupBannerTests {
    private func banner(_ state: String, step: String? = nil, isWatching: Bool = false, canRunSetup: Bool = true) -> CloudConnectionBanner? {
        CloudConnectionBanner.ofSetup(SetupRecord(state: state, step: step), isWatching: isWatching, canRunSetup: canRunSetup)
    }

    @Test func setupRunningSaysWhichStepAndOffersToWatch() {
        let running = banner("running", step: "prepare")
        #expect(running?.tone == .progress)
        #expect(running?.title == "Setting up this Cloud workspace: preparing the machine")
        #expect(running?.actions == [.watchSetup])
    }

    @Test func aStepThisVersionDoesNotKnowIsStillNamed() {
        #expect(banner("running", step: "seeding")?.title == "Setting up this Cloud workspace: seeding")
        #expect(banner("running")?.title == "Setting up this Cloud workspace…")
    }

    @Test func setupFailedOffersTheOutputAndRunningItAgain() {
        #expect(banner("failed")?.actions == [.watchSetup, .runSetupAgain])
        #expect(banner("failed", canRunSetup: false)?.actions == [.watchSetup])
        #expect(banner("failed", isWatching: true, canRunSetup: false)?.actions.isEmpty == true)
        #expect(banner("failed")?.tone == .failure)
    }

    @Test func nothingIsSaidOnceSetupIsDoneOrWasNeverRun() {
        #expect(banner("succeeded") == nil)
        #expect(banner("skipped") == nil)
        #expect(CloudConnectionBanner.ofSetup(nil, isWatching: false, canRunSetup: true) == nil)
    }

    @Test func watchingItAlreadyOffersNoButtonToWatchIt() {
        #expect(banner("running", isWatching: true)?.actions.isEmpty == true)
    }

    @Test func noUserFacingWordNamesTheProvider() {
        for state in ["pending", "running", "failed"] {
            let banner = CloudConnectionBanner.ofSetup(SetupRecord(state: state), isWatching: false, canRunSetup: true)
            let words = ([banner?.title, banner?.message].compactMap { $0 } + (banner?.actions ?? []).map(\.title))
                .joined(separator: " ").lowercased()
            #expect(!words.contains("sprite") && !words.contains("fly") && !words.contains("machine") && !words.contains("runner"))
        }
    }
}

@Suite struct CloudPromptReadinessTests {
    private func account(github: Bool, keys: [AgentKeyStatus]) -> RunbloomAccount {
        RunbloomAccount(id: "u", name: "Freek", email: "f@s.be", githubConnected: github, agentKeys: keys, teams: [])
    }

    @Test func githubComesFirst() {
        let notice = CloudPromptReadiness(account: account(github: false, keys: []), teamID: "t", agent: "claude")
        #expect(notice?.sentence.contains("Connect GitHub") == true)
        #expect(notice?.opensRunbloom == true)
    }

    @Test func aMissingKeyForThisAgentIsSaidByName() {
        let keys = [AgentKeyStatus(teamID: "t", agent: "claude", teamKey: true, personalKey: false),
                    AgentKeyStatus(teamID: "t", agent: "codex", teamKey: false, personalKey: false)]
        let ready = account(github: true, keys: keys)
        #expect(CloudPromptReadiness(account: ready, teamID: "t", agent: "claude") == nil)
        #expect(CloudPromptReadiness(account: ready, teamID: "t", agent: "codex")?.sentence.contains("Codex") == true)
    }

    @Test func anAccountThatSaysNothingAboutKeysIsNotAccused() {
        #expect(CloudPromptReadiness(account: account(github: true, keys: []), teamID: "t", agent: "claude") == nil)
        #expect(CloudPromptReadiness(account: nil, teamID: "t", agent: "claude") == nil)
    }

    @Test func aRefusalKeepsRunbloomsWordsAndOffersTheWayBack() {
        let refusal = RunbloomRefusal(status: 403, code: "no_push_access", message: "You cannot push to spatie/bloom.")
        let notice = CloudRefusalNotice(refusal: refusal)
        #expect(notice.sentence == "You cannot push to spatie/bloom.")
        #expect(notice.opensRunbloom)
        #expect(!CloudRefusalNotice(message: "The connection dropped.", code: "internal").opensRunbloom)
    }
}
