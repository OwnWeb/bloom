import Foundation

/// A model Claude Code says it runs, as its own `initialize` answer describes it.
public struct ClaudeModel: Sendable, Hashable {
    /// What `--model` takes: `opus[1m]`, `sonnet`, `claude-fable-5-1[1m]`.
    public var id: String
    /// "Opus 5 with 1M context", read off the CLI's own description, which names the version where
    /// its display name ("Opus (1M context)") does not.
    public var label: String
    public var efforts: [String]
    public var supportsFastMode: Bool
    /// The one the CLI recommends: whichever entry resolves to what its `default` entry does.
    public var isDefault: Bool

    public init(id: String, label: String, efforts: [String], supportsFastMode: Bool = false, isDefault: Bool = false) {
        self.id = id
        self.label = label
        self.efforts = efforts
        self.supportsFastMode = supportsFastMode
        self.isDefault = isDefault
    }
}

/// Claude Code's models, **from the CLI itself** rather than from a table Bloom keeps.
///
/// **One source, and it is not ours.** A Bloom Cloud machine listed only Codex's models, because
/// Codex has a `model/list` call and Claude Code seemed not to, and each client carried its own
/// Claude list: the Mac's is a literal in the app target, and the web could offer only the model a
/// chat was already on. Claude Code does answer the question: its stream-json `initialize` control
/// request returns `models`, each with its `supportedEffortLevels` and whether it has a fast mode,
/// the `[1m]` variants included. Measured on claude 2.1.276 on 19 September 2026: it answers in
/// half a second, starts no model turn and so costs nothing, and exits when its input closes.
///
/// **The list depends on who asks.** With no account the same CLI listed Opus with 1M context,
/// Sonnet and Haiku, and left out Fable, which a signed-in account was offered. A machine has no
/// key outside a turn, so this is the list a machine can honestly give; a model a person's own key
/// unlocks is still one they can type.
///
/// **Asked from a scratch directory, never from the worktree**, because `claude` in a project runs
/// that project's hooks, and listing models must not run a repository's code outside a turn.
public enum ClaudeModelList {
    static let request = #"{"type":"control_request","request_id":"bloom-models","request":{"subtype":"initialize"}}"# + "\n"

    public static func read(cwd: String = AgentScratchDirectory.current()) async throws -> [ClaudeModel] {
        // A cap on a CLI that never answers rather than a measurement: it answers in under a second.
        let result = try await Shell.run(
            "claude", ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"],
            cwd: cwd, stdin: request, timeout: .seconds(30)
        )
        return parse(result.stdout)
    }

    /// The models in the `initialize` answer among the lines Claude Code wrote, in its order. The
    /// `default` entry is an alias rather than a model, so it is left out and marks the model it
    /// resolves to instead.
    public static func parse(_ output: String) -> [ClaudeModel] {
        for line in output.split(whereSeparator: \.isNewline) {
            guard let json = JSONValue.parse(Data(line.utf8)), json["type"]?.stringValue == "control_response",
                  let listed = json["response"]?["response"]?["models"]?.arrayValue else { continue }
            let recommended = listed.first { $0["value"]?.stringValue == "default" }?["resolvedModel"]?.stringValue
            var models: [ClaudeModel] = []
            var markedDefault = false
            for entry in listed {
                guard let id = entry["value"]?.stringValue, !id.isEmpty, id != "default" else { continue }
                let isDefault = !markedDefault && recommended != nil && entry["resolvedModel"]?.stringValue == recommended
                markedDefault = markedDefault || isDefault
                models.append(ClaudeModel(
                    id: id, label: label(entry, id: id),
                    efforts: (entry["supportedEffortLevels"]?.arrayValue ?? []).compactMap(\.stringValue),
                    supportsFastMode: entry["supportsFastMode"]?.boolValue ?? false,
                    isDefault: isDefault
                ))
            }
            return models
        }
        return []
    }

    /// "Sonnet 5" from "Sonnet 5 · Efficient for routine tasks", falling back to the display name.
    static func label(_ entry: JSONValue, id: String) -> String {
        let separator = " \u{00B7} "
        if let description = entry["description"]?.stringValue, description.contains(separator),
           let name = description.components(separatedBy: separator).first?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            return name
        }
        return entry["displayName"]?.stringValue ?? id
    }
}

/// `ClaudeModelList`, fetched once per fifteen minutes however many clients ask.
public final class ClaudeModelCatalog: Sendable {
    public static let shared = ClaudeModelCatalog(fetch: { try await ClaudeModelList.read() })

    private let cache: AgentModelCache<ClaudeModel>

    public init(fetch: @escaping @Sendable () async throws -> [ClaudeModel], now: @escaping @Sendable () -> Date = Date.init) {
        cache = AgentModelCache(fetch: fetch, now: now)
    }

    public func models() async throws -> [ClaudeModel] {
        try await cache.models()
    }
}
