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

    /// **A spinner that outlived its turn.** runbloom.app's summary said `running`, the turn ended
    /// on the machine, and nothing told the summary: the sidebar span beside a conversation that
    /// had already answered. The stream carried the event that ended it, so while the stream is
    /// open the stream is believed.
    @Test func aLiveMachineOutranksAStaleSummary() {
        let item = CloudWorkspaceItem(id: "a", teamID: "t", name: "n", branch: "b", state: "running")
        #expect(CloudWorkspaceStatus(item: item) == .running, "the poll still says so")
        #expect(CloudWorkspaceStatus(item: item, activity: .idle) == .asleep || CloudWorkspaceStatus(item: item, activity: .idle) == .idle)
        #expect(CloudSidebarMark.name(for: item, activity: .idle) != "running")
        #expect(CloudSidebarMark.name(for: item, activity: nil) == "running", "no stream, no opinion")
    }

    /// And the other direction: a machine that has started a turn the poll has not seen yet says so
    /// at once rather than a poll's interval later.
    @Test func aLiveMachineIsBelievedBeforeTheSummaryCatchesUp() {
        let item = CloudWorkspaceItem(id: "a", teamID: "t", name: "n", branch: "b", state: "idle")
        #expect(CloudSidebarMark.name(for: item, activity: .running) == "running")
        #expect(CloudSidebarMark.name(for: item, activity: .settingUp(step: "clone")) == "settingUp")
        #expect(CloudSidebarMark.name(for: item, activity: .waiting(kind: "permission")) == "awaitingPermission")
    }

    @Test func setupSaysWhichStep() {
        let item = CloudWorkspaceItem(id: "a", teamID: "t", name: "n", branch: "b", state: "setting_up",
                                      summary: CloudWorkspaceSummary(setup: .init(state: "running", step: "prepare")))
        #expect(CloudWorkspaceStatus(item: item).phrase == "Setting up: preparing")
    }
}

@Suite struct PendingOpeningPromptTests {
    private let controls = ComposerControlsRecord(agent: "claude", model: "claude-opus-5", effort: "high", permissionMode: "acceptEdits", interactionMode: "build")
    /// What the machine would open a new chat with, which is a different answer from the one above.
    private let machine = ComposerControlsRecord(agent: "codex", model: "gpt-5.5", effort: "medium", permissionMode: "auto", interactionMode: "build")

    @Test func opensAChatFirstThenSendsIntoIt() {
        var prompt = PendingOpeningPrompt(workspaceID: "w", text: "Fix the queue", controls: controls)
        let first = prompt.nextOperation(defaults: machine)
        #expect(first.operation == .newChat(controls: controls))
        #expect(first.commandID == prompt.chatCommandID)
        prompt.chatID = "c1"
        #expect(prompt.nextOperation(defaults: machine).operation == .send(chatID: "c1", text: "Fix the queue"))
        #expect(prompt.nextOperation(defaults: machine).commandID == prompt.sendCommandID)
    }

    /// The ordinary case: nobody changed the controls in the create window, so the chat opens with
    /// what the machine says a new chat opens with rather than with a guess made before it existed.
    @Test func aPromptThatChoseNothingOpensWithTheMachinesOwnAnswer() {
        let prompt = PendingOpeningPrompt(workspaceID: "w", text: "Fix the queue", controls: nil)
        #expect(prompt.nextOperation(defaults: machine).operation == .newChat(controls: machine))
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
    /// A connection that dropped says nothing for the first two seconds, which is the window a
    /// runner restarting itself lives in. The phase carries the message either way; what the two
    /// seconds decide is when the column starts drawing it. See `WorkspaceConnection.retryingNotice`.
    @Test func aRetryingConnectionStillCarriesItsSentenceAndAWayForward() {
        let banner = CloudConnectionBanner.of(.retrying("The connection closed."))
        #expect(banner?.tone == .caution)
        #expect(banner?.title == "Reconnecting…")
        #expect(banner?.message == "The connection closed.")
        #expect(banner?.actions == [.retry])
        #expect(banner?.dismissalKey == nil, "a workspace that cannot be reached is not a banner to hide")
    }

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

    /// The same shape as an empty state: a title, a sentence that says what is true, and something
    /// to press wherever a person can do anything about it.
    @Test func everyBannerSaysATitleAndASentence() {
        let phases: [WorkspaceConnection.Phase] = [
            .connecting(waking: true), .asleep, .notReady(message: "Still starting.", retryAfter: 5), .archived,
            .noAccess("Removed."), .retrying("Offline."), .limited(LimitNotice(limit: "monthly_usage", message: "Over budget.")),
            .limited(LimitNotice(limit: "concurrent_machines", message: "Twenty running.")),
        ]
        for phase in phases {
            let banner = CloudConnectionBanner.of(phase)
            #expect(banner?.title.isEmpty == false, "\(phase) has no title")
            #expect(banner?.message?.isEmpty == false, "\(phase) has no sentence")
        }
    }

    /// It used to offer a button to the setup tab. There is no such tab: a machine's setup is a
    /// row at the head of its conversation, which is already on screen behind the banner.
    @Test func aMachineThatIsNotReadySaysSoWithNothingToPress() {
        let banner = CloudConnectionBanner.of(.notReady(message: "Still starting.", retryAfter: 5))
        #expect(banner?.message == "Still starting.")
        #expect(banner?.actions.isEmpty == true)
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
         "cloud_workspaces": {"enabled": true, "setup_complete": false, "github_connected": true, "github_app_installed": false,
                              "has_project": false, "has_agent_key": true, "setup_url": "https://runbloom.app/account/spatie"}}
        """)
        #expect(!team.isReadyForCloudWorkspaces)
        let notice = try #require(TeamSetupNotice(team: team, environment: environment))
        #expect(notice.steps == ["Install the Bloom GitHub App for the team.", "Add a repository as a project."])
        // The first step still to take is the one the button goes to, and installing the GitHub App
        // is taken on the team's own page rather than a page under it.
        #expect(notice.buttonTitle == "Install the GitHub App on runbloom.app")
        #expect(notice.page?.absoluteString == "https://runbloom.app/account/spatie")
    }

    @Test func aTeamNotInEarlyAccessSaysSo() throws {
        let team = try team(#"{"id": "t", "name": "Side", "cloud_workspaces_enabled": false, "cloud_workspaces": {"enabled": false, "has_agent_key": false}}"#)
        let notice = try #require(TeamSetupNotice(team: team, environment: environment))
        #expect(notice.sentence.contains("early access"))
        // Still worth doing before early access arrives, so still listed.
        #expect(notice.steps == ["Add a Claude Code or Codex API key."])
    }

    /// runbloom.app counts the steps itself, and may count one this version has never heard of.
    @Test func runbloomsOwnVerdictOnTheStepsWins() throws {
        let team = try team(#"{"id": "t", "name": "Spatie", "cloud_workspaces_enabled": true, "cloud_workspaces": {"enabled": true, "setup_complete": false, "github_connected": true, "github_app_installed": true, "has_project": true, "has_agent_key": true}}"#)
        #expect(!team.isReadyForCloudWorkspaces)
        let notice = try #require(TeamSetupNotice(team: team, environment: environment))
        #expect(notice.steps.isEmpty)
        #expect(notice.sentence.contains("needs a few things"))
    }

    @Test func fieldsBesideTheTeamAreReadToo() throws {
        let team = try team(#"{"id": "t", "name": "Flat", "enabled": true, "has_agent_key": false, "setup_url": "https://runbloom.app/teams/t"}"#)
        #expect(team.cloudWorkspacesEnabled)
        #expect(team.setup?.missing == ["Add a Claude Code or Codex API key."])
    }

    @Test func aReadyTeamOrOneThatSaysNothingHasNoNotice() throws {
        let ready = try team(#"{"id": "t", "name": "Ready", "cloud_workspaces_enabled": true, "cloud_workspaces": {"enabled": true, "setup_complete": true, "github_connected": true, "github_app_installed": true, "has_project": true, "has_agent_key": true}}"#)
        #expect(TeamSetupNotice(team: ready, environment: environment) == nil)
        let silent = try team(#"{"id": "t", "name": "Old", "cloud_workspaces_enabled": true}"#)
        #expect(silent.setup == nil)
        #expect(TeamSetupNotice(team: silent, environment: environment) == nil)
    }

    /// The step names outlived the banner they were written for: a machine's setup is a row in the
    /// transcript now, and the row says which step is running in the same words.
    @Test func aSetupStepIsNamedInWordsAndAnUnknownOneIsSaidAsItStands() {
        #expect(CloudConnectionBanner.stepName("prepare") == "preparing the machine")
        #expect(CloudConnectionBanner.stepName("seeding") == "seeding")
        #expect(CloudConnectionBanner.stepName("") == nil)
        #expect(CloudConnectionBanner.stepName(nil) == nil)
    }

    @Test func aSetupPageElsewhereIsNotOffered() throws {
        let team = try team(#"{"id": "t", "name": "X", "cloud_workspaces_enabled": true, "cloud_workspaces": {"has_project": false, "setup_url": "https://evil.test/setup"}}"#)
        #expect(TeamSetupNotice(team: team, environment: environment)?.page == nil)
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

    /// runbloom.app renamed this one after shipping it twice. Both spellings mean the same thing
    /// and both have to offer the way to the page where GitHub is connected.
    @Test func bothSpellingsOfAMissingGitHubConnectionGoBackToRunbloom() {
        let message = "Connect GitHub to your Bloom account first."
        #expect(CloudRefusalNotice(message: message, code: "github_not_connected").opensRunbloom)
        #expect(CloudRefusalNotice(message: message, code: "no_github_connection").opensRunbloom)
    }
}

@Suite struct CloudEmptyStateTests {
    private let environment = RunbloomEnvironment(origin: RunbloomEnvironment.productionOrigin, urlScheme: "bloomcloud")

    private func account(_ teams: [RunbloomTeam]) -> RunbloomAccount {
        RunbloomAccount(id: "u", name: "Freek", email: "f@s.be", githubConnected: true, teams: teams)
    }

    private func team(enabled: Bool, setup: TeamSetup?) -> RunbloomTeam {
        RunbloomTeam(id: "t", name: "Spatie", cloudWorkspacesEnabled: enabled, setup: setup)
    }

    private var complete: TeamSetup {
        TeamSetup(enabled: true, setupComplete: true, githubConnected: true, githubAppInstalled: true, hasProject: true, hasAgentKey: true,
                  setupURL: URL(string: "https://runbloom.app/account/spatie"))
    }

    @Test func signedOutSaysWhatACloudWorkspaceIsAndOffersSigningIn() {
        let state = CloudEmptyState.noWorkspaces(isSignedIn: false, account: nil, environment: environment)
        #expect(state.action == .signIn)
        #expect(state.action?.title == "Sign in to your Bloom account")
        #expect(!state.sentence.isEmpty)
    }

    @Test func aReadyTeamWithNoWorkspacesOffersCreatingOne() {
        let state = CloudEmptyState.noWorkspaces(isSignedIn: true, account: account([team(enabled: true, setup: complete)]), environment: environment)
        #expect(state.title == "No Cloud workspaces yet")
        #expect(state.action == .createWorkspace)
        #expect(state.steps.isEmpty)
    }

    @Test func aTeamMissingAStepOffersThatStepsOwnPage() {
        var setup = complete
        setup.setupComplete = false
        setup.hasProject = false
        let state = CloudEmptyState.noWorkspaces(isSignedIn: true, account: account([team(enabled: true, setup: setup)]), environment: environment)
        #expect(state.title == "One more step first")
        #expect(state.steps == ["Add a repository as a project."])
        #expect(state.action == .open(URL(string: "https://runbloom.app/account/spatie/projects"), title: "Add a project on runbloom.app"))
    }

    @Test func aMissingKeyGetsTheKeysPage() {
        var setup = complete
        setup.setupComplete = false
        setup.hasAgentKey = false
        let state = CloudEmptyState.noWorkspaces(isSignedIn: true, account: account([team(enabled: true, setup: setup)]), environment: environment)
        #expect(state.action == .open(URL(string: "https://runbloom.app/account/spatie/agent-keys"), title: "Add an API key on runbloom.app"))
    }

    @Test func earlyAccessSaysSoAndStillOffersTheWayThere() {
        let state = CloudEmptyState.noWorkspaces(
            isSignedIn: true, account: account([team(enabled: false, setup: TeamSetup(enabled: false, setupURL: URL(string: "https://runbloom.app/account/spatie")))]),
            environment: environment
        )
        #expect(state.title == "Cloud workspaces are in early access")
        #expect(state.action?.title == TeamSetupNotice.genericButtonTitle)
    }

    @Test func everyEmptyStateHasATitleASentenceAndSomethingToPressWhereThereIsAnything() {
        let states = [
            CloudEmptyState.noWorkspaces(isSignedIn: false, account: nil, environment: environment),
            CloudEmptyState.noWorkspaces(isSignedIn: true, account: account([team(enabled: true, setup: complete)]), environment: environment),
            CloudEmptyState.nothingOpen(hasWorkspaces: true, isSignedIn: true, account: nil, environment: environment),
            CloudEmptyState.missingWorkspace,
            CloudEmptyState.privateWorkspace(ownerName: "Alex"),
        ]
        for state in states {
            #expect(!state.title.isEmpty)
            #expect(state.sentence.hasSuffix(".") || state.sentence.hasSuffix("…"))
            let words = ([state.title, state.sentence] + state.steps + [state.action?.title ?? ""]).joined(separator: " ").lowercased()
            #expect(!words.contains("sprite") && !words.contains("fly.io") && !words.contains("runner"))
        }
        // The one state with nothing to press says why rather than offering a button that lies.
        #expect(CloudEmptyState.privateWorkspace(ownerName: nil).action == nil)
    }

    @Test func theCentreColumnAsksForAChoiceOnlyWhenThereIsOne() {
        let none = CloudEmptyState.nothingOpen(hasWorkspaces: false, isSignedIn: false, account: nil, environment: environment)
        #expect(none.action == .signIn)
        let some = CloudEmptyState.nothingOpen(hasWorkspaces: true, isSignedIn: true, account: nil, environment: environment)
        #expect(some.title == "No Cloud workspace open")
        #expect(some.action == .createWorkspace)
    }
}

@Suite struct CloudChecksWordingTests {
    @Test func theRollupIsSaidTheWayGhSaysIt() {
        #expect(CloudChecksWording.summary(CloudChecksRollup(total: 3, passed: 3, failed: 0, pending: 0)) == "3 checks passed")
        #expect(CloudChecksWording.summary(CloudChecksRollup(total: 1, passed: 1, failed: 0, pending: 0)) == "1 check passed")
        #expect(CloudChecksWording.summary(CloudChecksRollup(total: 4, passed: 2, failed: 1, pending: 1)) == "1 of 4 failing")
        #expect(CloudChecksWording.summary(CloudChecksRollup(total: 2, passed: 0, failed: 0, pending: 2)) == "2 queued")
        #expect(CloudChecksWording.summary(CloudChecksRollup(total: 0, passed: 0, failed: 0, pending: 0)).isEmpty)
        #expect(CloudChecksWording.summary(nil).isEmpty)
    }

    /// The same idea arrives spelled two ways, `passed` in the pull request and `succeeded` in the
    /// checks body. Both have to come out as one sentence.
    @Test func theChecksSummarySaysTheSameAsTheRollup() {
        let summary = CloudChecksSummary(state: "success", total: 3, succeeded: 3, failed: 0, pending: 0, skipped: 0)
        #expect(CloudChecksWording.summary(summary) == "3 checks passed")
    }

    @Test func freshnessIsSaidOnlyWhenItIsWorthSaying() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(CloudChecksWording.freshness(fetchedAt: now.addingTimeInterval(-30), isStale: false, now: now) == nil)
        #expect(CloudChecksWording.freshness(fetchedAt: now.addingTimeInterval(-60), isStale: true, now: now)
            == "Last checked with GitHub a minute ago.")
        #expect(CloudChecksWording.freshness(fetchedAt: now.addingTimeInterval(-600), isStale: false, now: now)
            == "Last checked with GitHub 10 minutes ago.")
        #expect(CloudChecksWording.freshness(fetchedAt: now.addingTimeInterval(-7_200), isStale: false, now: now)
            == "Last checked with GitHub 2 hours ago.")
        #expect(CloudChecksWording.freshness(fetchedAt: nil, isStale: true, now: now)
            == "GitHub has not been asked about this branch yet.")
        #expect(CloudChecksWording.freshness(fetchedAt: nil, isStale: false, now: now) == nil)
    }
}

@Suite struct CloudRunnerNoticeTests {
    private let at = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func aRollbackUnderwayCannotBePutAway() {
        let banner = CloudConnectionBanner.ofRunner(CloudRunnerNotice(
            kind: CloudRunnerNotice.beingRolledBack,
            message: "Version 0.2.0 did not start, so Bloom is putting this Cloud workspace back on 0.1.9.", at: at
        ))
        #expect(banner?.tone == .progress)
        #expect(banner?.dismissalKey == nil)
        #expect(banner?.message?.contains("0.1.9") == true)
    }

    @Test func anOutcomeRestsAndCanBePutAway() {
        let back = CloudConnectionBanner.ofRunner(CloudRunnerNotice(
            kind: CloudRunnerNotice.rolledBack, message: "This Cloud workspace is running 0.1.9 again.", at: at
        ))
        #expect(back?.tone == .caution)
        #expect(back?.dismissalKey != nil)

        let failed = CloudConnectionBanner.ofRunner(CloudRunnerNotice(
            kind: CloudRunnerNotice.failed, message: "The update failed and could not be undone.", at: at
        ))
        #expect(failed?.tone == .failure)
        #expect(failed?.dismissalKey != nil)
        #expect(failed?.dismissalKey != back?.dismissalKey, "two different outcomes are two different banners")
    }

    /// The sentence is runbloom.app's, so nothing here writes one of its own, and a notice with
    /// nothing in it is no banner rather than an empty one.
    @Test func theSentenceIsShownAsItStands() {
        let notice = CloudRunnerNotice(kind: CloudRunnerNotice.failed, message: "Anything at all.", at: at)
        #expect(CloudConnectionBanner.ofRunner(notice)?.message == "Anything at all.")
        #expect(CloudConnectionBanner.ofRunner(CloudRunnerNotice(kind: CloudRunnerNotice.failed, message: "")) == nil)
        #expect(CloudConnectionBanner.ofRunner(nil) == nil)
    }

    /// Interrupted is a resting state like the two outcomes: a machine switched off halfway through
    /// an update may be on either version until it is next updated, and that does not end by itself.
    @Test func anInterruptedUpdateRestsAndCanBePutAway() {
        let banner = CloudConnectionBanner.ofRunner(CloudRunnerNotice(
            kind: CloudRunnerNotice.interrupted,
            message: "An update was interrupted, so this Cloud workspace may be on either version.", at: at
        ))
        #expect(banner?.tone == .caution)
        #expect(banner?.title == "This Cloud workspace's update was interrupted")
        #expect(banner?.dismissalKey != nil)
    }

    @Test func aKindThisVersionDoesNotKnowIsStillSaid() {
        let banner = CloudConnectionBanner.ofRunner(CloudRunnerNotice(kind: "update_paused", message: "Something new.", at: at))
        #expect(banner?.message == "Something new.")
        #expect(banner?.dismissalKey != nil)
    }
}

@Suite struct CloudSidebarMarkTests {
    private func item(
        state: String = "idle", unread: Bool = false, files: Int = 0, pullRequest: String? = nil, awake: Bool = true
    ) -> CloudWorkspaceItem {
        let request = pullRequest.map { #"{"number": 1, "url": "u", "title": "t", "state": "\#($0)"}"# } ?? "null"
        let json = #"""
        {"id": "w1", "team_id": "t1", "name": "Queue", "branch": "b", "base_branch": "main", "state": "\#(state)",
         "unread": \#(unread),
         "summary": {"awake": \#(awake), "diff": {"files": \#(files), "additions": 1, "deletions": 0},
           "pull_request": \#(request)}}
        """#
        return (try? JSONDecoder().decode(CloudWorkspaceItem.self, from: Data(json.utf8)))
            ?? CloudWorkspaceItem(id: "w1", teamID: "t1", name: "Queue", branch: "b", baseBranch: "main", state: state)
    }

    /// The agent's own states win, in the order a local row weighs them.
    @Test func theAgentComesFirst() {
        #expect(CloudSidebarMark.name(for: item(state: "running", unread: true)) == "running")
        #expect(CloudSidebarMark.name(for: item(state: "waiting_for_input")) == "awaitingPermission")
        #expect(CloudSidebarMark.name(for: item(state: "setting_up")) == "settingUp")
        #expect(CloudSidebarMark.name(for: item(state: "setup_failed")) == "setupFailed")
        // A prompt held by a team limit is nothing running and nothing about to.
        #expect(CloudSidebarMark.name(for: item(state: "blocked")) == "setupFailed")
    }

    /// Then the branch: GitHub first, then unread, then whether there is anything on it.
    @Test func thenTheBranch() {
        #expect(CloudSidebarMark.name(for: item(unread: true, pullRequest: "merged")) == "merged")
        #expect(CloudSidebarMark.name(for: item(pullRequest: "closed")) == "closed")
        #expect(CloudSidebarMark.name(for: item(pullRequest: "open")) == "pullRequestOpen")
        #expect(CloudSidebarMark.name(for: item(unread: true, files: 3)) == "unread")
        #expect(CloudSidebarMark.name(for: item(files: 3)) == "changed")
        #expect(CloudSidebarMark.name(for: item()) == "clean")
    }

    /// An asleep machine is a resting state, not a mark of its own: the row says what the branch
    /// says, the way a local workspace nobody is running anything in does.
    @Test func asleepIsNotAState() {
        #expect(CloudSidebarMark.name(for: item(files: 2, awake: false)) == "changed")
    }
}

@Suite struct CloudSendOutcomeTests {
    @Test func aPromptThatWentSaysNothing() {
        #expect(CloudSendOutcome(failure: nil) == .sent)
        #expect(CloudSendOutcome(failure: nil).sentence == nil)
    }

    @Test func aRefusalIsTheMachinesOwnSentence() {
        let outcome = CloudSendOutcome(failure: .refused(WireError(.busy, "This chat is already running a turn.")))
        #expect(outcome == .failed("This chat is already running a turn."))
        #expect(outcome.sentence == "This chat is already running a turn.")
        #expect(outcome.title == "Could not send the message")
    }

    /// The one that matters: a runner that died while the agent was already holding the prompt
    /// answers `outcome_unknown` rather than resolving it, because the alternative is running it
    /// twice. Told as a failure, the obvious next thing somebody does is send it again.
    @Test func anUnknownOutcomeIsNotAFailure() {
        let outcome = CloudSendOutcome(failure: .refused(WireError(.outcomeUnknown, "The workspace restarted while it was running.")))
        #expect(outcome == .unknown("The workspace restarted while it was running."))
        #expect(outcome.title == "That message may already have been sent")
        let sentence = outcome.sentence ?? ""
        #expect(sentence.contains("does not know whether"))
        #expect(sentence.contains("Read the conversation before sending it again."))
        #expect(sentence.contains("The workspace restarted while it was running."))
    }

    @Test func noAnswerAtAllIsAPlainFailure() {
        #expect(CloudSendOutcome(failure: .noAnswer("It did not answer.")) == .failed("It did not answer."))
    }
}
