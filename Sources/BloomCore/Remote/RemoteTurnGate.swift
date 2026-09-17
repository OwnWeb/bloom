import Foundation

/// runbloom.app's half of a turn: registering it while the prompter's token is fresh, starting it
/// when it reaches the front of the queue, and ending it.
///
/// **Two steps, because a queue outlives a token.** A prompt can wait behind a long turn for far
/// longer than the five minutes a session token lives, and the key for it must be tied to a person
/// who asked while their access was valid. So the token is handed on at `register`, and `start`
/// later needs only the workspace secret. A leaked secret alone therefore cannot mint a turn. See
/// docs/REMOTE-WORKSPACES.md, "How a key reaches a turn".
///
/// A protocol so the runtime is testable with no runbloom.app, and so the Mac could run the same
/// runtime with `UngatedTurns` if it ever wanted to.
public protocol RemoteTurnGate: Sendable {
    func register(_ kind: RemoteTurnKind, chat: SessionID?, agent: AgentKind?, caller: RemoteCaller) async throws -> String
    func start(turnID: String) async throws -> RemoteTurnGrant
    func end(turnID: String) async
}

public enum RemoteTurnKind: String, Sendable, Hashable {
    case turn
    case terminal
}

/// What starting a turn hands the machine: keys for the agents the prompter may use, and the
/// prompter's personal environment, both for that turn's processes only.
public struct RemoteTurnGrant: Sendable, Hashable {
    public var agentKeys: [AgentKind: RemoteAgentKey]
    public var environment: [String: String]

    public init(agentKeys: [AgentKind: RemoteAgentKey] = [:], environment: [String: String] = [:]) {
        self.agentKeys = agentKeys
        self.environment = environment
    }

    /// The process environment for an agent of this kind: the key under the variable its CLI
    /// reads, over the personal environment, so a personal variable cannot shadow the key.
    public func environment(for agent: AgentKind) -> [String: String] {
        var values = environment
        if let key = agentKeys[agent] {
            switch agent {
            case .codex: values["OPENAI_API_KEY"] = key.key
            case .grok: values["XAI_API_KEY"] = key.key
            case .claudeCode, .cursor, .openCode: values["ANTHROPIC_API_KEY"] = key.key
            }
        }
        return values
    }

    /// What decides whether a running agent process can take this turn or has to be relaunched:
    /// the key's identity, never the person, so teammates on the team key never cause a relaunch.
    public func launchIdentity(for agent: AgentKind) -> String {
        let personal = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        return (agentKeys[agent]?.identity ?? "") + "\n" + personal
    }
}

public struct RemoteAgentKey: Sendable, Hashable {
    public var key: String
    /// A hash of the key from runbloom.app, never the key, so comparing two costs nothing secret.
    public var identity: String
    /// `team` or `personal`.
    public var source: String

    public init(key: String, identity: String, source: String) {
        self.key = key
        self.identity = identity
        self.source = source
    }
}

/// Why runbloom.app would not start a turn.
public enum RemoteTurnRefusal: Error, Sendable, Hashable {
    /// A team limit. The prompt stays queued and marked; see `DeliveryBlock`.
    case blocked(DeliveryBlock)
    /// Anything a person has to fix before this prompt can go: no key, no GitHub, no longer a
    /// collaborator, or a turn registered too long ago. The prompt stays queued and the queue
    /// pauses with the sentence.
    case refused(code: String, message: String)
}

/// No runbloom.app: every turn starts, with no key, and agents use whatever sign-in the machine
/// already has. For tests, and for running the runtime anywhere a person is already the only user.
public struct UngatedTurns: RemoteTurnGate {
    public init() {}
    public func register(_ kind: RemoteTurnKind, chat: SessionID?, agent: AgentKind?, caller: RemoteCaller) async throws -> String { "" }
    public func start(turnID: String) async throws -> RemoteTurnGrant { RemoteTurnGrant() }
    public func end(turnID: String) async {}
}
