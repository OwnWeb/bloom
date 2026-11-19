import Foundation

/// The settings a chat's runner was started with, and whether a change to them needs a new one.
///
/// It lived privately in `TranscriptModel`, where the decision could not be tested. It is the
/// decision that kills a process, so it belongs where a test can reach it.
public struct RunnerPreferences: Equatable, Sendable {
    public var model: String
    public var effort: String
    public var permissionMode: String
    public var agentKind: String
    /// A launch setting of a process that outlives every turn, so a change in Settings or in
    /// the chat's own picker reaches an open chat only by starting that process again.
    public var advisor: AdvisorLaunch

    public init(session: Session, advisor: AdvisorLaunch) {
        model = session.model
        effort = session.effort
        permissionMode = session.permissionMode.rawValue
        agentKind = session.agentKind.rawValue
        // Only Claude Code has one, and another backend must not restart over it.
        self.advisor = session.agentKind == .claudeCode ? advisor : .consult(.inherit)
    }

    /// An advisor change, often made in Settings for every chat, waits for the turn to end
    /// rather than killing a process somebody is steering. A model or effort change on a backend
    /// that takes them live never restarts: the runner is handed them instead, see
    /// `adoptsComposerSettings(of:)`.
    public func restarts(for next: Self, midTurn: Bool) -> Bool {
        var compared = next
        if midTurn { compared.advisor = advisor }
        if takesComposerSettingsLive(next) {
            compared.model = model
            compared.effort = effort
        }
        return self != compared
    }

    /// Whether the kept runner has to be told about a new model or effort.
    public func adoptsComposerSettings(of next: Self) -> Bool {
        takesComposerSettingsLive(next) && (model != next.model || effort != next.effort)
    }

    private func takesComposerSettingsLive(_ next: Self) -> Bool {
        agentKind == next.agentKind && AgentKind(rawValue: agentKind)?.takesComposerSettingsLive == true
    }
}
