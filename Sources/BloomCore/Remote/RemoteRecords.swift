import BloomProtocol
import Foundation

// Core values as the version 1 wire spells them. Here rather than in BloomProtocol because the
// protocol package knows nothing of BloomCore, and in one file because every conversion follows
// the same two rules: names are the ones runbloom.app uses, and an agent's own JSON goes through
// as JSON rather than being reshaped.

extension AgentKind {
    /// The name runbloom.app and the wire use, which is the CLI's executable name: `claude`, not
    /// `claudeCode`, because that is what a person types and what a key is registered for.
    public var wireName: String { executableName }

    /// A static function rather than an initialiser, because `AgentKind.init` is passed to
    /// `flatMap` elsewhere and a second failable initialiser taking a string made that ambiguous.
    public static func named(wire name: String) -> AgentKind? {
        AgentKind.allCases.first { $0.wireName == name }
    }
}

extension MessageAuthor {
    public var record: AuthorRecord { AuthorRecord(userID: userID, name: name, email: email) }
}

extension JSONValue {
    var wireValue: WireValue { WireValue.parse(Data(compactJSON.utf8)) ?? .null }
}

extension WireValue {
    var jsonValue: JSONValue { JSONValue.parse(data) ?? .null }
}

extension Session {
    func record(lastSeq: Int) -> ChatRecord {
        ChatRecord(
            id: id.rawValue, title: title, agent: agentKind.wireName, model: model, effort: effort,
            permissionMode: permissionMode.rawValue, interactionMode: interactionMode.rawValue, state: state.rawValue,
            parentChatID: parentSessionID?.rawValue, lastSeq: lastSeq, createdAt: createdAt, updatedAt: updatedAt,
            closedAt: archivedAt
        )
    }
}

extension ClosedChat {
    var record: ClosedChatRecord {
        ClosedChatRecord(
            id: id.rawValue,
            title: title,
            agent: agentKind.wireName,
            messageCount: messageCount,
            closedAt: closedAt
        )
    }
}

extension Message {
    var record: MessageRecord {
        MessageRecord(
            cursor: id, chatID: sessionID.rawValue, seq: seq, kind: kind.rawValue,
            payload: WireValue.parse(payload) ?? .string(String(decoding: payload, as: UTF8.self)),
            author: author?.record, createdAt: createdAt, durationMS: durationMS, refID: refID,
            audience: audience?.record, via: via?.record
        )
    }
}

extension PendingPermissionAsk {
    var record: QuestionRecord {
        QuestionRecord(requestID: requestID, chatID: sessionID.rawValue, ask: WireValue.parse(ask.raw) ?? .null, askedAt: askedAt)
    }
}

extension ComposerControls {
    var record: ComposerControlsRecord {
        ComposerControlsRecord(
            agent: agentKind.wireName, model: model, effort: effort, permissionMode: permissionMode.rawValue,
            interactionMode: interactionMode.rawValue, fastMode: isFastMode, codexFastMode: codexFastMode,
            outputStyle: outputStyle, codexContextWindow: codexContextWindow
        )
    }

    init(record: ComposerControlsRecord) throws {
        guard let agent = AgentKind.named(wire: record.agent), agent.canRunWorkspaces else {
            throw RemoteFailure(.agentUnavailable, "Choose an agent that can run a chat.")
        }
        guard let permissionMode = PermissionMode(rawValue: record.permissionMode) else {
            throw RemoteFailure.invalid("Choose a permission mode from the menu.")
        }
        guard !record.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteFailure.invalid("Choose a model.")
        }
        self.init(
            model: record.model, effort: record.effort, agentKind: agent, permissionMode: permissionMode,
            isFastMode: record.fastMode, outputStyle: record.outputStyle, codexContextWindow: record.codexContextWindow,
            codexFastMode: record.codexFastMode, interactionMode: InteractionMode(rawValue: record.interactionMode) ?? .build
        )
    }
}

extension Answer {
    var decision: PermissionDecision {
        get throws {
            switch self {
            case .allowOnce: return .allow(scope: .once)
            case .allowSession: return .allow(scope: .session)
            case .allowProject: return .allow(scope: .project)
            case .deny(let message, let endsTurn):
                let text = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return .deny(message: text.isEmpty ? PermissionDecision.defaultDenyMessage : text, endsTurn: endsTurn)
            case .approvePlan(let raw):
                guard let mode = PermissionMode(rawValue: raw) else { throw RemoteFailure.invalid("Choose a permission mode to implement the plan in.") }
                return .approvePlan(mode: mode)
            case .question(let input): return .answer(input: input.jsonValue)
            }
        }
    }
}

extension Workspace {
    func record(setup: SetupRecord, reporting: ReportingRecord? = nil, services: [ServiceRecord] = []) -> WorkspaceRecord {
        WorkspaceRecord(id: id.rawValue, name: name, branch: branch, baseBranch: baseBranch, setup: setup,
                        reporting: reporting, services: services)
    }
}
