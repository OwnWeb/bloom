import Foundation

/// One ACP event Bloom cares about, decoded from `opencode acp`.
///
/// The turn payloads are the shared ACP ones. What is OpenCode's own is the session: it carries
/// no model list in `initialize`, and describes model and effort as config options instead.
public enum OpenCodeEvent: Sendable, Hashable {
    case sessionReady(OpenCodeSession)
    case update(ACPSessionUpdate)
    case permission(ACPPermissionRequest)
    case promptCompleted(ACPPromptResult)
    case closed(reason: String)
    case unknown(method: String, raw: Data)
}

public struct OpenCodeSession: Sendable, Hashable {
    public let id: String
    public let options: OpenCodeConfigOptions

    public init(id: String, options: OpenCodeConfigOptions = OpenCodeConfigOptions()) {
        self.id = id
        self.options = options
    }
}

/// The `configOptions` of a session: what can be selected, and what is selected now.
///
/// Returned whole by `session/new`, `session/resume` and every `session/set_config_option`.
/// **The effort option is absent when the current model has no effort levels**, so an empty
/// `efforts` is an answer rather than a decoding failure.
public struct OpenCodeConfigOptions: Sendable, Hashable {
    public struct Choice: Sendable, Hashable {
        public let value: String
        public let name: String

        public init(value: String, name: String = "") {
            self.value = value
            self.name = name.isEmpty ? value : name
        }
    }

    public static let modelID = "model"
    public static let effortID = "effort"
    public static let modeID = "mode"

    public var models: [Choice]
    public var currentModel: String
    public var efforts: [Choice]
    public var currentEffort: String
    /// `build`, `plan`, and any primary agent the user's config defines.
    public var modes: [Choice]
    public var currentMode: String

    public init(
        models: [Choice] = [],
        currentModel: String = "",
        efforts: [Choice] = [],
        currentEffort: String = "",
        modes: [Choice] = [],
        currentMode: String = ""
    ) {
        self.models = models
        self.currentModel = currentModel
        self.efforts = efforts
        self.currentEffort = currentEffort
        self.modes = modes
        self.currentMode = currentMode
    }

    public func offersEffort(_ effort: String) -> Bool {
        efforts.contains { $0.value == effort }
    }

    public func offersMode(_ mode: String) -> Bool {
        modes.contains { $0.value == mode }
    }

    /// Reads a reply that carries `configOptions`. Options are found by id, never by position.
    public static func decode(_ json: JSONValue) -> OpenCodeConfigOptions {
        var decoded = OpenCodeConfigOptions()
        for option in json["configOptions"]?.arrayValue ?? [] {
            let choices = (option["options"]?.arrayValue ?? []).compactMap { choice -> Choice? in
                guard let value = choice["value"]?.stringValue, !value.isEmpty else { return nil }
                return Choice(value: value, name: choice["name"]?.stringValue ?? "")
            }
            let current = option["currentValue"]?.stringValue ?? ""
            switch option["id"]?.stringValue {
            case modelID:
                decoded.models = choices
                decoded.currentModel = current
            case effortID:
                decoded.efforts = choices
                decoded.currentEffort = current
            case modeID:
                decoded.modes = choices
                decoded.currentMode = current
            default:
                continue
            }
        }
        return decoded
    }
}
