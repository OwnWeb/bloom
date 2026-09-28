import Foundation

/// Claude Code's own model list, in the terms the composer's model menu already reads for Codex
/// and Grok, so a third backend needs no branch of its own there.
///
/// In a file of its own rather than in `ClaudeModelCatalog.swift`, which is the machine's branch's
/// file taken whole: a change to it here would be a conflict the day the two branches meet.
extension ClaudeModel {
    public var agentModel: AgentModel {
        AgentModel(
            id: id,
            displayName: label,
            isDefault: isDefault,
            supportedEfforts: efforts.map { AgentModelEffort(id: $0, label: CodexReasoningEffort(id: $0).label) },
            // Bloom's own default for a Claude chat, when the model takes it. A model that takes no
            // effort at all (Haiku) has none to default to, and an empty default is what says so.
            defaultEffort: efforts.contains("high") ? "high" : (efforts.first ?? "")
        )
    }
}

extension AgentModelSource {
    public static func claude(_ catalog: ClaudeModelCatalog = .shared) -> AgentModelSource {
        AgentModelSource(
            models: { try await catalog.models().map(\.agentModel) },
            invalidate: {}
        )
    }
}
