import BloomCore
import Foundation
import Observation

/// Which agent CLIs are signed in on this Mac, and which binary each one is, for the parts of the
/// app that have to decide something from that without a window of their own.
///
/// The automatic router is the first of those. It may only ask an agent that can answer, and an
/// installed CLI with no account answers every question with a sign-in error. The Agents pane and
/// onboarding each build an `AgentCatalog` of their own for their own screens, and before this
/// nothing outlived those screens: the create window had no way to know that Codex was signed in
/// unless somebody had just looked.
///
/// One catalog, built with the owner's executable overrides and rebuilt when they change, because a
/// catalog's overrides are fixed at init. The Agents pane hands over whatever it has just detected,
/// so looking at that pane is also a refresh here, and the create window asks for one when the last
/// answer is older than `staleAfter`.
@MainActor
@Observable
final class AgentAvailability {
    static let shared = AgentAvailability()

    /// The agents whose CLI is installed and signed in. See `AgentStatus.Connection`.
    private(set) var connected: Set<AgentKind> = []
    /// Whether any detection has finished, so a caller can tell "nothing is connected" from
    /// "nobody has looked yet".
    private(set) var hasLoaded = false

    @ObservationIgnored private var overrides: [AgentKind: String] = [:]
    @ObservationIgnored private var store: Store?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadedAt: Date?

    /// How old an answer may be before the create window asks again. Detection runs each CLI's
    /// `--version`, which is a few processes rather than a network call, so this is about not
    /// doing it on every open of a window rather than about cost.
    static let staleAfter: TimeInterval = 300

    /// Called once the database is open, from the same place `ComposerModelCatalog` is configured.
    func configure(store: Store) {
        self.store = store
        refresh()
    }

    /// Detects again, with the overrides as the store has them now.
    func refresh() {
        loadTask?.cancel()
        let store = store
        loadTask = Task { [weak self] in
            let overrides = await AgentCatalog.executablePathOverrides(in: store)
            let statuses = await AgentCatalog(overrides: overrides).statuses()
            guard !Task.isCancelled else { return }
            self?.adopt(statuses: statuses, overrides: overrides)
        }
    }

    /// A refresh, unless the last answer is recent enough to trust.
    func refreshIfStale(now: Date = Date()) {
        if let loadedAt, now.timeIntervalSince(loadedAt) < Self.staleAfter { return }
        refresh()
    }

    /// What a screen that has just run its own detection found, so this does not run it twice.
    func adopt(statuses: [AgentStatus], overrides: [AgentKind: String]) {
        connected = Set(statuses.filter { $0.connection == .connected }.map(\.kind))
        self.overrides = overrides
        hasLoaded = true
        loadedAt = Date()
    }

    /// The binary to launch for an agent: the owner's own path when the Agents pane names one.
    func executable(for kind: AgentKind) -> String {
        AgentCatalog.executable(for: kind, override: overrides[kind])
    }
}
