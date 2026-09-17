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
/// its machine sleeps. It is read when the app becomes active and every twenty seconds while it is
/// (the design's fifteen to thirty), and never while Bloom is in the background, which is also
/// when the notifications derived from it are the ones worth having; the first poll on coming back
/// reports what changed while away.
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
    /// Whether the create sheet is up.
    var isCreating = false
    /// The workspace whose archive confirmation is up. See `CloudArchiveSheet`.
    var archiving: CloudWorkspaceID?

    /// The open ones. Outside observation, like `AppModel.workspaceModels`: what the window draws
    /// is the state inside each session.
    @ObservationIgnored private var sessions: [CloudWorkspaceID: CloudWorkspaceSession] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var activation: (any NSObjectProtocol)?
    @ObservationIgnored private var lastReading: [CloudWorkspaceItem]?
    /// Created here and not read back yet, so their first reading can still notify. See
    /// `CloudWorkspaceNotices`.
    @ObservationIgnored private var watching: Set<String> = []

    static let pollInterval: Duration = .seconds(20)
    private static let promptsKey = "cloudWorkspaces.pendingOpeningPrompts"
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
        do {
            try await signIn.signIn(presenting: window)
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
        pollTask?.cancel()
        pollTask = nil
        for session in sessions.values { session.close() }
        sessions.removeAll()
        await signIn.signOut()
        account = nil
        items = []
        lastReading = nil
        listProblem = nil
        accountState = .signedOut
        if case .cloud = app?.selection { app?.selection = .home }
    }

    // MARK: The list

    /// Reads the account and every team's list.
    func refresh() async {
        let api = api
        do {
            let account = try await api.account()
            self.account = account
            accountState = .signedIn
            var gathered: [CloudWorkspaceItem] = []
            for team in account.cloudTeams {
                gathered += try await api.cloudWorkspaces(team: team.id)
            }
            gathered.sort { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            absorb(gathered)
            listProblem = nil
        } catch let failure as SignInFailure where failure == .signedOut {
            await signOut()
        } catch let refusal as RunbloomRefusal where refusal.isUnauthenticated {
            await signOut()
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
        // A selected workspace that is no longer listed was archived somewhere else.
        if let selected = app?.selection.cloudWorkspaceID, !reading.contains(where: { $0.id == selected.rawValue }) {
            close(selected)
            app?.selection = .home
        }
    }

    func item(_ id: CloudWorkspaceID) -> CloudWorkspaceItem? {
        items.first { $0.id == id.rawValue }
    }

    func team(_ id: String) -> RunbloomTeam? {
        account?.teams.first { $0.id == id }
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self, !Task.isCancelled else { return }
                if NSApp.isActive { await self.refresh() }
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
    }

    /// Creates a Cloud workspace, keeps its opening prompt, and selects it.
    func create(_ request: CreateRequest) async throws -> CloudWorkspaceItem {
        let item = try await api.createCloudWorkspace(team: request.team.id, request: CreateCloudWorkspace(
            project: request.project.id, name: request.name, branch: request.branch,
            baseBranch: request.baseBranch.flatMap { $0.isEmpty ? nil : $0 }
        ))
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty {
            let controls = await openingControls()
            hold(PendingOpeningPrompt(workspaceID: item.id, text: prompt, controls: controls.cloudRecord))
        }
        watching.insert(item.id)
        items.insert(item, at: 0)
        app?.selection = .cloud(CloudWorkspaceID(item.id))
        return item
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

    /// Tells runbloom.app to archive, which deletes the machine. The machine's own confirmation, when
    /// there is a machine to ask, is `CloudWorkspaceSession.archive`.
    func archiveOnRunbloom(_ id: CloudWorkspaceID) async throws {
        try await api.archiveCloudWorkspace(id.rawValue)
        release(promptFor: id.rawValue)
        close(id)
        items.removeAll { $0.id == id.rawValue }
        if app?.selection == .cloud(id) { app?.selection = .home }
    }
}
