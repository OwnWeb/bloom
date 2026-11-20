import Foundation
import Observation
import BloomCore

@MainActor
@Observable
final class ComposerPlanningSupport {
    static let shared = ComposerPlanningSupport()
    /// What Codex reported. Read it through `isAvailable(on:)`, which knows it is Codex's.
    private(set) var codexIsAvailable = true
    private(set) var isChecking = false
    @ObservationIgnored private var store: Store?
    @ObservationIgnored private var revision = 0

    func refresh(from store: Store) async {
        self.store = store
        guard !isChecking else { return }
        let revision = self.revision
        do {
            let available = try await store.setting(CodexPlanningCapability.unavailableKey) != "1"
            guard revision == self.revision, !isChecking else { return }
            if codexIsAvailable != available { codexIsAvailable = available }
        } catch {
            // A failed preference read is not evidence about the provider's capabilities.
            // Retain the last known answer until the next transcript-driven refresh.
        }
    }

    func isAvailable(on agent: AgentKind) -> Bool {
        CodexPlanningCapability.planIsAvailable(on: agent, codexReportedUnavailable: !codexIsAvailable)
    }

    /// A retry is explicit and only resets discovery. It never sends a prompt or starts a turn.
    func checkAgain() async {
        guard let store, !isChecking else { return }
        isChecking = true
        revision += 1
        defer { isChecking = false }
        do {
            try await store.setSetting(CodexPlanningCapability.rescanKey, UUID().uuidString)
            try await store.setSetting(CodexPlanningCapability.unavailableKey, nil)
            codexIsAvailable = true
        } catch { codexIsAvailable = false }
    }
}
