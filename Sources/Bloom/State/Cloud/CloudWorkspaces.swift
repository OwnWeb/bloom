import AppKit
import BloomAuthentication
import BloomClient
import BloomCore
import BloomProtocol
import Observation

/// Cloud workspaces in this window: the Bloom account they need, runbloom.app's list of them, and
/// one `CloudWorkspaceSession` per workspace somebody has opened.
///
/// **Signing in is optional and stays out of the way.** Bloom needs no account to run on a Mac, so
/// nothing here asks anybody to sign in: a signed out Mac shows no Cloud section in the sidebar at
/// all, and the one place that says what an account is for is its own Settings pane.
///
/// **The list is polled, and polling never wakes a machine.** runbloom.app answers from the last
/// summary each machine posted, so the sidebar can say a workspace is waiting for an answer while
/// its machine sleeps. It is read when the app becomes active, every twenty seconds while it is (the
/// design's fifteen to thirty), and every minute while Bloom is in the background, which is when
/// the notifications derived from it are the ones worth having.
@MainActor
@Observable
final class CloudWorkspaces {
    enum AccountState: Equatable {
        case signedOut
        case signingIn
        /// Signed in, reading the account.
        case loading
        case signedIn
        /// Signed in, and the account could not be read. The sentence says why.
        case failed(String)
    }

    let environment: RunbloomEnvironment
    @ObservationIgnored let signIn: BloomAccountSignIn
    @ObservationIgnored private weak var app: AppModel?

    private(set) var accountState: AccountState = .signedOut
    private(set) var account: RunbloomAccount?
    /// Every Cloud workspace in every team with the feature, newest first.
    private(set) var items: [CloudWorkspaceItem] = []
    /// Why the last read of the list failed, or nil when it worked.
    private(set) var listProblem: String?
    /// Prompts typed at create, held until their machine takes them. See `PendingOpeningPrompt`.
    private(set) var pendingPrompts = PendingOpeningPrompts()
    /// The workspace whose archive confirmation is up. See `CloudArchivePopover`.
    var archiving: CloudWorkspaceID?

    /// Where that confirmation hangs, which is whatever the person clicked.
    ///
    /// The popover replaced a sheet, and a popover needs a control that is still on screen. The
    /// sidebar row's own box is the usual one; the pull request strip asks from its own Archive
    /// button; and `.window` is the last resort for a caller with nothing on screen to point at,
    /// which is better than bringing the sheet back for that one case.
    enum ArchiveAnchor: Equatable { case row, pullRequest, window }

    private(set) var archivingAnchor = ArchiveAnchor.row

    func askToArchive(_ id: CloudWorkspaceID, from anchor: ArchiveAnchor) {
        archivingAnchor = anchor
        archiving = id
    }

    /// Whether the confirmation for `id` belongs to this control.
    func isAskingToArchive(_ id: CloudWorkspaceID, at anchor: ArchiveAnchor) -> Bool {
        archiving == id && archivingAnchor == anchor
    }

    /// The open ones. Outside observation, like `AppModel.workspaceModels`: what the window draws
    /// is the state inside each session.
    @ObservationIgnored private var sessions: [CloudWorkspaceID: CloudWorkspaceSession] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var activation: (any NSObjectProtocol)?
    @ObservationIgnored private var lastReading: [CloudWorkspaceItem]?
    /// Created here and not read back yet, so their first reading can still notify. See
    /// `CloudWorkspaceNotices`.
    @ObservationIgnored private var watching: Set<String> = []
    /// Moved by every sign in and sign out, and checked after every await in `refresh`, so an
    /// answer for an account that has since signed out is dropped rather than drawn.
    @ObservationIgnored private var generation = 0
    /// Workspaces whose machine has already accepted `archive`, so a retry after runbloom.app could
    /// not be reached goes straight to runbloom.app rather than asking the machine again, which
    /// would answer with a fresh preview and read as something having changed.
    @ObservationIgnored private var archivedOnMachine: Set<CloudWorkspaceID> = []

    static let pollInterval: Duration = .seconds(20)
    static let backgroundPollInterval: Duration = .seconds(60)
    private static let promptsKey = "cloudWorkspaces.pendingOpeningPrompts"
    private static let dismissedBannersKey = "cloudWorkspaces.dismissedBanners"
    private static let originKey = "cloudWorkspaces.runbloomOrigin"

    init() {
        let schemes = (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? [])
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        environment = RunbloomEnvironment.resolve(
            environment: ProcessInfo.processInfo.environment,
            setting: UserDefaults.standard.string(forKey: Self.originKey),
            urlSchemes: schemes
        )
        signIn = BloomAccountSignIn(environment: environment)
        pendingPrompts = PendingOpeningPrompts.decode(UserDefaults.standard.data(forKey: Self.promptsKey), now: Date())
        let stored = UserDefaults.standard.dictionary(forKey: Self.dismissedBannersKey) as? [String: [String]] ?? [:]
        dismissedBanners = CloudBannerDismissals(stored: stored)
    }

    /// Which banners have been put away, per workspace. A setup that failed stays failed until
    /// somebody fixes the project's script, so its banner would otherwise sit over every visit for
    /// the life of the workspace; the state itself is still in the Setup tab, which the banner says.
    private(set) var dismissedBanners = CloudBannerDismissals()

    func dismiss(_ banner: CloudConnectionBanner, for id: CloudWorkspaceID) {
        dismissedBanners.dismiss(banner, workspaceID: id.rawValue)
        saveDismissedBanners()
    }

    private func saveDismissedBanners() {
        UserDefaults.standard.set(dismissedBanners.stored, forKey: Self.dismissedBannersKey)
    }

    /// The API for the kept sign in. Its base comes from the discovery document the sign in was
    /// issued under, falling back to the origin's conventional path before the keychain is read.
    var api: RunbloomAPI {
        let base = signIn.apiBaseURL ?? environment.origin.appending(path: "api/v1")
        return RunbloomAPI(baseURL: base) { [signIn] force in
            try await signIn.accessToken(forceRefresh: force)
        }
    }

    var isSignedIn: Bool {
        switch accountState {
        case .signedOut, .signingIn: false
        default: true
        }
    }

    /// Called once the window's model has bootstrapped. Reads the keychain, and when a sign in is
    /// kept, the account and the list.
    func attach(_ app: AppModel) {
        self.app = app
        guard signIn.isSignedIn else { return }
        accountState = .loading
        startPolling()
        Task { await refresh() }
    }

    func shutdown() {
        pollTask?.cancel()
        pollTask = nil
        if let activation { NotificationCenter.default.removeObserver(activation) }
        activation = nil
        for session in sessions.values { session.close() }
        sessions.removeAll()
    }

    // MARK: Signing in and out

    func beginSignIn() async {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) else {
            accountState = .failed("Open a Bloom window to sign in from.")
            return
        }
        accountState = .signingIn
        generation += 1
        do {
            try await signIn.signIn(presenting: window)
            // Somebody who has just signed in is using Bloom Cloud, so a sidebar they once hid it
            // from shows it again. See `CloudSidebarPresence`.
            UserDefaults.standard.set(true, forKey: CloudSidebarPresence.settingKey)
            accountState = .loading
            startPolling()
            await refresh()
        } catch let failure as SignInFailure {
            accountState = signIn.isSignedIn ? .signedIn : (failure.isCancellation ? .signedOut : .failed(failure.message))
        } catch {
            accountState = .failed(error.localizedDescription)
        }
    }

    func signOut() async {
        generation += 1
        pollTask?.cancel()
        pollTask = nil
        if let activation { NotificationCenter.default.removeObserver(activation) }
        activation = nil
        for session in sessions.values { session.close() }
        sessions.removeAll()
        account = nil
        items = []
        lastReading = nil
        listProblem = nil
        watching = []
        // Held prompts belong to the account that typed them. Sent after somebody else signs in,
        // they would be queued under that person's name and on their key.
        pendingPrompts = PendingOpeningPrompts()
        UserDefaults.standard.removeObject(forKey: Self.promptsKey)
        NotificationService.shared.removeCloudNotifications()
        accountState = .signedOut
        await signIn.signOut()
        if case .cloud = app?.selection { app?.selection = .home }
    }

    // MARK: The list

    /// Reads the account and every team's list.
    func refresh() async {
        let api = api
        let began = generation
        do {
            let account = try await api.account()
            guard began == generation else { return }
            self.account = account
            accountState = .signedIn
            var gathered: [CloudWorkspaceItem] = []
            for team in account.cloudTeams {
                gathered += try await api.cloudWorkspaces(team: team.id)
            }
            guard began == generation else { return }
            gathered.sort { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            absorb(gathered)
            listProblem = nil
            // Every refresh, and not only signing in and reconnecting: Bloom is often open with no
            // stream to the workspace that wrote, and a message would otherwise wait for hours.
            // Signing in and coming back to the app both refresh, so this covers them too.
            Task { await app?.drainMacMessages() }
        } catch let failure as SignInFailure where failure == .signedOut {
            if began == generation { await signOut() }
        } catch let refusal as RunbloomRefusal where refusal.isUnauthenticated {
            if began == generation { await signOut() }
        } catch where began != generation {
            return
        } catch let refusal as RunbloomRefusal {
            if account == nil { accountState = .failed(refusal.message) }
            listProblem = refusal.message
        } catch {
            let sentence = "runbloom.app could not be reached. \(error.localizedDescription)"
            if account == nil { accountState = .failed(sentence) }
            listProblem = sentence
        }
    }

    /// Reads one workspace again, straight after something changed it here.
    func refresh(_ id: CloudWorkspaceID) async {
        guard let item = try? await api.cloudWorkspace(id.rawValue) else { return }
        var next = items
        if item.archivedAt != nil || item.state == "archived" {
            next.removeAll { $0.id == item.id }
        } else if let index = next.firstIndex(where: { $0.id == item.id }) {
            next[index] = item
        } else {
            next.insert(item, at: 0)
        }
        items = next
    }

    private func absorb(_ reading: [CloudWorkspaceItem]) {
        let notices = CloudWorkspaceNotices.between(previous: lastReading, current: reading, watching: watching)
        watching.subtract(reading.map(\.id))
        lastReading = reading
        if reading != items { items = reading }
        for notice in notices { NotificationService.shared.cloudWorkspace(notice) }
        // The workspace on screen is being read, so what arrived in it since is not unread.
        if let selected = app?.selection.cloudWorkspaceID, NSApp.isActive, item(selected)?.unread == true {
            Task { await markRead(selected) }
        }
        // A selected workspace that is no longer listed was archived somewhere else.
        if let selected = app?.selection.cloudWorkspaceID, !reading.contains(where: { $0.id == selected.rawValue }) {
            close(selected)
            app?.selection = .home
        }
    }

    /// Marks a workspace read on runbloom.app, which is where unread lives, per person.
    func markRead(_ id: CloudWorkspaceID) async {
        guard let index = items.firstIndex(where: { $0.id == id.rawValue }), items[index].unread else { return }
        items[index].unread = false
        try? await api.markRead(id.rawValue)
    }

    func item(_ id: CloudWorkspaceID) -> CloudWorkspaceItem? {
        items.first { $0.id == id.rawValue }
    }

    /// Whether this team has a key for either agent, which is what a first turn needs. Personal
    /// keys count: runbloom.app uses one in a workspace that is not shared.
    func hasAnyAgentKey(team: String) -> Bool {
        guard let account, !account.agentKeys.isEmpty else { return true }
        return account.hasAgentKey(team: team, agent: "claude") || account.hasAgentKey(team: team, agent: "codex")
    }

    /// What to say where a Cloud workspace list is empty, and what to offer. See `CloudEmptyState`.
    var emptyState: CloudEmptyState {
        CloudEmptyState.noWorkspaces(isSignedIn: isSignedIn, account: account, environment: environment)
    }

    /// The same, for the centre column, which can also say "choose one".
    var nothingOpenState: CloudEmptyState {
        CloudEmptyState.nothingOpen(hasWorkspaces: !items.isEmpty, isSignedIn: isSignedIn, account: account, environment: environment)
    }

    /// The page on runbloom.app closest to a Cloud workspace's cause: its team's own setup page
    /// when the account named one, and the current team's page otherwise.
    ///
    /// Written as four statements rather than one expression, because one line of optional chaining
    /// with a `??` between two differently produced `URL`s is past what the CI runner's type checker
    /// will finish: green here, red there, which is the green that counts. See `SidebarView`, which
    /// carries the same note for the same reason.
    func runbloomPage(forWorkspace id: CloudWorkspaceID) -> URL {
        let workspace: CloudWorkspaceItem? = item(id)
        let team: RunbloomTeam? = workspace.flatMap { self.team($0.teamID) }
        if let page = team?.setup?.setupPage(on: environment) { return page }
        return environment.teamPage
    }

    func team(_ id: String) -> RunbloomTeam? {
        account?.teams.first { $0.id == id }
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            var sinceLastRead: Duration = .zero
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                sinceLastRead += Self.pollInterval
                guard let self, !Task.isCancelled else { return }
                // Slower in the background rather than not at all: a Cloud workspace waiting for an
                // answer is worth a banner most while the person is in another app.
                guard NSApp.isActive || sinceLastRead >= Self.backgroundPollInterval else { continue }
                sinceLastRead = .zero
                await self.refresh()
            }
        }
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    // MARK: Open workspaces

    /// The session for a workspace, made on first use. Opening it is `CloudWorkspaceSession.open`.
    func session(for id: CloudWorkspaceID) -> CloudWorkspaceSession {
        if let existing = sessions[id] { return existing }
        let session = CloudWorkspaceSession(id: id, cloud: self)
        sessions[id] = session
        return session
    }

    func existingSession(for id: CloudWorkspaceID) -> CloudWorkspaceSession? {
        sessions[id]
    }

    func close(_ id: CloudWorkspaceID) {
        sessions.removeValue(forKey: id)?.close()
    }

    var appModel: AppModel? { app }

    // MARK: Creating

    struct CreateRequest {
        var team: RunbloomTeam
        var project: RunbloomProject
        var name: String
        var branch: String
        var baseBranch: String?
        var prompt: String
        /// Whether the machine runs the project's setup. False is the create window's box
        /// unticked, and it means the workspace is usable at once rather than after a step nobody
        /// asked for. See `CreateCloudWorkspace.runSetup`.
        var runSetup = true
        /// What the first turn runs with, when somebody chose it in the create window. Nil means
        /// "whatever the machine would open a chat with", which is the better answer and is not
        /// known until the machine exists. See `PendingOpeningPrompt.controls`.
        var controls: ComposerControls?
        /// The draft whose staging directory holds the files the prompt names, or nil for a prompt
        /// carrying none. See `PendingOpeningPrompt.stagingDraftID`.
        var stagingDraftID: String?
    }

    /// Creates a Cloud workspace, keeps its opening prompt, and selects it unless told not to.
    ///
    /// `selecting: false` is an agent's `cloud_workspace_start`, for the reason `workspace_start`
    /// passes `select: false`: a row appearing is news, a selection moving while somebody types is
    /// an interruption.
    func create(_ request: CreateRequest, selecting: Bool = true) async throws -> CloudWorkspaceItem {
        let item = try await api.createCloudWorkspace(team: request.team.id, request: CreateCloudWorkspace(
            project: request.project.id, name: request.name, branch: request.branch,
            baseBranch: request.baseBranch.flatMap { $0.isEmpty ? nil : $0 },
            // Sent only when it is false, so the body a default create posts is the one it has
            // always posted and a server that has not learned the field yet is not handed one.
            runSetup: request.runSetup ? nil : false
        ))
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty {
            // Only a deliberate choice is carried. Nothing chosen is held as nothing, so the turn
            // opens with what the machine says a new chat opens with rather than with a guess made
            // before the machine existed. A choice is still clamped, because a machine runs Claude
            // Code or Codex and anything else would be a picker that lied.
            let chosen = request.controls.map {
                [AgentKind.claudeCode, .codex].contains($0.agentKind) ? $0 : ComposerControls(hasWorktree: true)
            }
            hold(PendingOpeningPrompt(
                workspaceID: item.id, text: prompt, controls: chosen?.cloudRecord,
                stagingDraftID: request.stagingDraftID
            ))
        }
        watching.insert(item.id)
        items.insert(item, at: 0)
        if selecting { app?.selection = .cloud(CloudWorkspaceID(item.id)) }
        return item
    }

    /// One page of a project's branches as runbloom.app lists them, searched on its side, for the
    /// create sheet's "from main" list. See `CloudBaseBranches`.
    ///
    /// runbloom.app pages by number from 1; the list keeps a cursor, so the next page's number is
    /// the cursor. A branch pushed within the last minute may not be listed yet, since runbloom.app
    /// caches the list for sixty seconds, which is one reason a typed name is always a row.
    func branches(team: String, project: String, query: String, cursor: String?) async throws -> (names: [String], next: String?) {
        let page = cursor.flatMap(Int.init) ?? 1
        let answer = try await api.branches(team: team, project: project, search: query, page: page)
        return (answer.branches.map(\.name), answer.hasMore ? String(page + 1) : nil)
    }

    func projects(team: String) async throws -> [RunbloomProject] {
        try await api.projects(team: team)
    }

    /// What a new chat on a machine starts with: this Mac's own defaults for a new chat, when they
    /// name an agent a Cloud workspace runs, and Claude Code otherwise.
    func openingControls() async -> ComposerControls {
        let local = (try? await app?.resolvedControls(for: nil)) ?? ComposerControls()
        guard local.agentKind == .claudeCode || local.agentKind == .codex else { return ComposerControls(hasWorktree: true) }
        return local
    }

    func hold(_ prompt: PendingOpeningPrompt) {
        pendingPrompts.prompts[prompt.workspaceID] = prompt
        UserDefaults.standard.set(pendingPrompts.encoded, forKey: Self.promptsKey)
    }

    func release(promptFor workspaceID: String) {
        guard pendingPrompts.prompts.removeValue(forKey: workspaceID) != nil else { return }
        UserDefaults.standard.set(pendingPrompts.encoded, forKey: Self.promptsKey)
    }

    // MARK: Archiving

    enum ArchiveStep {
        case archived
        /// The machine's answer moved since the confirmation was read, so it is shown again.
        case moved(CloudArchiveConfirmation)
        case failed(String)
    }

    /// What archiving would lose. The machine is asked when it can be, which wakes it; runbloom.app's
    /// last summary speaks for a machine that cannot answer or a reader who cannot open it.
    /// What runbloom.app's last summary says would be lost, which is known at once and without
    /// anybody's machine. The sheet draws this immediately, so Archive is never disabled while
    /// something else is being asked. See `CloudArchivePopover`.
    func archiveConfirmationFromSummary(_ id: CloudWorkspaceID) -> CloudArchiveConfirmation {
        CloudArchiveConfirmation(summary: item(id)?.summary)
    }

    /// What the machine itself says would be lost, when it answers inside the bound. Nil when there
    /// is no machine to ask or it did not answer in time.
    ///
    /// **Bounded, because somebody is standing in front of a dialog.** `perform` is built for a
    /// runner restarting under an open window and keeps trying for a couple of minutes, which is
    /// right for a prompt and wrong for a question whose answer only enriches a sentence: the
    /// dialog sat on "Checking what would be lost…" with Archive disabled, on a machine that was
    /// never going to answer, which is the state somebody most wants to archive out of. Five
    /// seconds is a cap on a person waiting rather than a measurement of a machine.
    func machineArchivePreview(_ id: CloudWorkspaceID, within limit: Duration = .seconds(5)) async -> CloudArchiveConfirmation? {
        guard let item = item(id), item.canOpen, !["setting_up", "setup_failed", "error"].contains(item.state) else {
            return nil
        }
        let ask = Task { () -> CloudArchiveConfirmation? in
            guard let result = try? await self.session(for: id).perform(.archivePreview),
                  case .archivePreview(let preview) = result else { return nil }
            return CloudArchiveConfirmation(preview: preview)
        }
        let bound = Task {
            try? await Task.sleep(for: limit)
            ask.cancel()
        }
        defer { bound.cancel() }
        return await ask.value
    }

    /// Archives with a confirmation the person accepted: on the machine first when it was asked,
    /// which checks its answer again and winds the workspace down, then on runbloom.app, which
    /// deletes the machine.
    func archive(_ id: CloudWorkspaceID, confirmed confirmation: CloudArchiveConfirmation) async -> ArchiveStep {
        if let confirmationID = confirmation.confirmationID, !archivedOnMachine.contains(id) {
            do {
                let result = try await session(for: id).perform(.archive(confirmationID: confirmationID))
                if case .archivePreview(let moved) = result { return .moved(CloudArchiveConfirmation(preview: moved)) }
                archivedOnMachine.insert(id)
            } catch {
                // A machine that went away between the question and the answer is archived on
                // runbloom.app all the same: the person has already agreed to lose what it held.
                if case .refused(let wire) = error, wire.knownCode != .unavailable, wire.knownCode != .workspaceChanging {
                    return .failed(wire.message)
                }
            }
        }
        do {
            try await archiveOnRunbloom(id)
            return .archived
        } catch let refusal as RunbloomRefusal {
            return .failed(refusal.message)
        } catch {
            return .failed("runbloom.app could not be reached. \(error.localizedDescription)")
        }
    }

    /// Tells runbloom.app to archive, which deletes the machine. The machine's own confirmation, when
    /// there is a machine to ask, is `CloudWorkspaceSession.archive`.
    func archiveOnRunbloom(_ id: CloudWorkspaceID) async throws {
        try await api.archiveCloudWorkspace(id.rawValue)
        release(promptFor: id.rawValue)
        // Nothing to remember about a workspace that no longer exists, and a new one could be
        // given the same id by nothing more than bad luck.
        dismissedBanners.forget(workspaceID: id.rawValue)
        saveDismissedBanners()
        close(id)
        items.removeAll { $0.id == id.rawValue }
        if app?.selection == .cloud(id) { app?.selection = .home }
    }
}
