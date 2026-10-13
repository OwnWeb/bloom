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

extension Array where Element == ClaudeModel {
    /// Claude Code can lag a newly released model even while its full id works with `--model`.
    /// Keep the explicit Sonnet 5.5 choice until the CLI lists it or resolves `sonnet` to it.
    public var agentModels: [AgentModel] {
        guard !isEmpty else { return [] }
        var mapped = map(\.agentModel)
        if !contains(where: { $0.id == "claude-sonnet-5-5" || $0.resolvedModel == "claude-sonnet-5-5" }) {
            mapped.append(AgentModel(
                id: "claude-sonnet-5-5", displayName: "Sonnet 5.5",
                supportedEfforts: ["low", "medium", "high", "xhigh", "max"].map {
                    AgentModelEffort(id: $0, label: CodexReasoningEffort(id: $0).label)
                },
                defaultEffort: "medium"
            ))
        }
        return mapped
    }
}

extension AgentModelSource {
    public static func claude(_ catalog: ClaudeModelCatalog = .shared) -> AgentModelSource {
        AgentModelSource(
            models: { try await catalog.models().agentModels },
            invalidate: {}
        )
    }
}
