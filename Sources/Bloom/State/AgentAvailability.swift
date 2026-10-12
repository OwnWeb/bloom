import BloomCore
import Foundation
import Observation

/// Which agent CLIs are signed in on this Mac, outliving any one screen, so the router asks only
/// an agent that can answer. The Agents pane hands over what it detects; the create window
/// refreshes when the answer is older than `staleAfter`.
@MainActor
@Observable
final class AgentAvailability {
    static let shared = AgentAvailability()

    private(set) var connected: Set<AgentKind> = []
    /// Tells "nothing is connected" from "nobody has looked yet".
    private(set) var hasLoaded = false

    @ObservationIgnored private var overrides: [AgentKind: String] = [:]
    @ObservationIgnored private var store: Store?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadedAt: Date?

    static let staleAfter: TimeInterval = 300

    /// Detects at launch only when the router, its only reader, is on: detection runs every agent's
    /// `--version`.
    func configure(store: Store) {
        self.store = store
        if ModelRouterPreferences().isEnabled { refresh() }
    }

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

    func executable(for kind: AgentKind) -> String {
        AgentCatalog.executable(for: kind, override: overrides[kind])
    }
}
