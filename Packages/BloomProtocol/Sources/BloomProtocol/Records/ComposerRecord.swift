import Foundation

/// What a chat's composer is set to.
///
/// Last writer wins, as it does on a Mac with two windows open on one chat; the `composer` event
/// names who wrote it so a client can say so.
public struct ComposerControlsRecord: Codable, Sendable, Hashable {
    public var agent: String
    public var model: String
    public var effort: String
    public var permissionMode: String
    public var interactionMode: String
    public var fastMode: Bool
    /// Nil inherits Codex's own configuration.
    public var codexFastMode: Bool?
    public var outputStyle: String
    public var codexContextWindow: Int

    public init(
        agent: String, model: String, effort: String, permissionMode: String, interactionMode: String,
        fastMode: Bool = false, codexFastMode: Bool? = nil, outputStyle: String = "default", codexContextWindow: Int = 0
    ) {
        self.agent = agent
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.interactionMode = interactionMode
        self.fastMode = fastMode
        self.codexFastMode = codexFastMode
        self.outputStyle = outputStyle
        self.codexContextWindow = codexContextWindow
    }

    enum CodingKeys: String, CodingKey {
        case agent, model, effort
        case permissionMode = "permission_mode"
        case interactionMode = "interaction_mode"
        case fastMode = "fast_mode"
        case codexFastMode = "codex_fast_mode"
        case outputStyle = "output_style"
        case codexContextWindow = "codex_context_window"
    }
}

/// A chat's composer and the choices the server can offer it.
public struct ComposerRecord: Codable, Sendable, Hashable {
    public var chatID: String
    public var controls: ComposerControlsRecord
    /// The agents installed on this machine that can run a chat.
    public var availableAgents: [String]
    public var models: [ModelRecord]
    public var commands: [SlashCommandRecord]
    public var outputStyles: [String]

    public init(chatID: String, controls: ComposerControlsRecord, availableAgents: [String], models: [ModelRecord], commands: [SlashCommandRecord], outputStyles: [String]) {
        self.chatID = chatID
        self.controls = controls
        self.availableAgents = availableAgents
        self.models = models
        self.commands = commands
        self.outputStyles = outputStyles
    }

    enum CodingKeys: String, CodingKey {
        case controls, models, commands
        case chatID = "chat_id"
        case availableAgents = "available_agents"
        case outputStyles = "output_styles"
    }
}

public struct ModelRecord: Codable, Sendable, Hashable {
    public var agent: String
    public var id: String
    public var label: String
    public var efforts: [String]
    public var defaultEffort: String?
    public var isDefault: Bool

    public init(agent: String, id: String, label: String, efforts: [String], defaultEffort: String?, isDefault: Bool) {
        self.agent = agent
        self.id = id
        self.label = label
        self.efforts = efforts
        self.defaultEffort = defaultEffort
        self.isDefault = isDefault
    }

    enum CodingKeys: String, CodingKey {
        case agent, id, label, efforts
        case defaultEffort = "default_effort"
        case isDefault = "is_default"
    }
}

public struct SlashCommandRecord: Codable, Sendable, Hashable {
    public var name: String
    public var description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}
