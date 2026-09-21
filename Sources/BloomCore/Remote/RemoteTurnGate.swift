import Foundation

/// runbloom.app's half of a turn: registering it while the prompter's token is fresh, starting it
/// when it reaches the front of the queue, and ending it.
///
/// **Two steps, because a queue outlives a token.** A prompt can wait behind a long turn for far
/// longer than the five minutes a session token lives, and its authority must be tied to a person
/// who asked while their access was valid. So the token is handed on at `register`, and `start`
/// later needs only the workspace secret. A leaked secret alone therefore cannot mint a turn. See
/// docs/REMOTE-WORKSPACES.md, "How model authority reaches a turn".
/// A normal turn registers its exact model beside its agent. A terminal registers both as nil and
/// receives no model authority when it starts.
///
/// A protocol so the runtime is testable with no runbloom.app, and so the Mac could run the same
/// runtime with `UngatedTurns` if it ever wanted to.
public protocol RemoteTurnGate: Sendable {
    func register(
        _ kind: RemoteTurnKind, chat: SessionID?, agent: AgentKind?, model: String?, caller: RemoteCaller
    ) async throws -> String
    func start(turnID: String) async throws -> RemoteTurnGrant
    func end(turnID: String) async
}

public enum RemoteTurnKind: String, Sendable, Hashable {
    case turn
    case terminal
}

/// What starting a turn hands the process boundary. A Cloud Runner puts only its local gateway
/// credential here. Provider credentials and server grants never enter BloomCore or a child.
public struct RemoteTurnGrant: Sendable, Hashable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public var agentEnvironments: [AgentKind: [String: String]]
    public var environment: [String: String]
    /// An opaque bearer bound by runbloom.app to this exact running turn or terminal. A Runner
    /// refuses a missing value; nil remains useful for local and unit-test gates.
    public var githubCredentialGrant: RemoteGithubCredentialGrant?

    public init(agentEnvironments: [AgentKind: [String: String]] = [:], environment: [String: String] = [:],
                githubCredentialGrant: RemoteGithubCredentialGrant? = nil) {
        self.agentEnvironments = agentEnvironments
        self.environment = environment
        self.githubCredentialGrant = githubCredentialGrant
    }

    /// The process environment for an agent of this kind. The Runner-provided gateway values win
    /// over personal variables, and the ordinary provider aliases are removed first.
    public func environment(for agent: AgentKind) -> [String: String] {
        var result = ProviderCredentialEnvironment.untrustedProcess(environment)
        result.merge(agentEnvironments[agent] ?? [:]) { _, gateway in gateway }
        return result
    }

    /// What a process or shell launched with this grant carries that belongs to one person: the
    /// wire name of every person-bound agent, and `environment` when there is personal environment.
    /// Empty means nothing of anybody's own. See `PersonalCredentials`.
    public func personalMarks(for agents: [AgentKind]) -> Set<String> {
        // A shared-workspace control call retires every person-bound model process. The opaque
        // grant intentionally does not reveal whether its upstream key was personal or team-owned.
        var marks = Set(agents.map(\.wireName))
        if !ProviderCredentialEnvironment.untrustedProcess(environment).isEmpty {
            marks.insert(PersonalCredentials.environmentMark)
        }
        return marks
    }

    /// Whether this grant shows the workspace became shared while something still holds personal
    /// credentials of this kind. runbloom.app hands out personal keys and personal environment
    /// only in a workspace nobody else is in, so a team key for an agent that something holds a
    /// personal key for, or a grant with no personal environment where something holds some, means
    /// those credentials must go even if the `control/shared` call never arrived.
    public func supersedes(_ marks: Set<String>) -> Bool {
        for mark in marks {
            if mark == PersonalCredentials.environmentMark {
                if environment.isEmpty { return true }
            }
        }
        return false
    }

    /// What decides whether a running agent process can take this turn or has to be relaunched.
    /// Local gateway credentials are unique to a turn, so Cloud agents do not retain authority.
    public func launchIdentity(for agent: AgentKind) -> String {
        let personal = ProviderCredentialEnvironment.untrustedProcess(environment)
            .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        let gateway = (agentEnvironments[agent] ?? [:])
            .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        return gateway + "\n" + personal
    }

    public var description: String {
        let agents = agentEnvironments.keys.map(\.wireName).sorted().joined(separator: ", ")
        let names = environment.keys.sorted().joined(separator: ", ")
        return "RemoteTurnGrant(local gateway for: [\(agents)], environment: [\(names)])"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["description": description]) }
}

/// The protocol-layer form of a person-bound grant. It stays in memory and redacts its bearer from every
/// interpolated or reflected description.
public struct RemoteGithubCredentialGrant: Sendable, Hashable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public var token: String
    public var expiresAt: Date
    public var revision: Int

    public init(token: String, expiresAt: Date, revision: Int) {
        self.token = token
        self.expiresAt = expiresAt
        self.revision = revision
    }

    public var description: String {
        "RemoteGithubCredentialGrant(expiresAt: \(expiresAt), revision: \(revision), token: [REDACTED])"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["description": description]) }
}

/// Trusted launch context assembled by the queue from its registered turn and stored author. It is
/// not decoded from a local credential request or read from the child environment.
public struct RemoteLaunchContext: Sendable, Hashable {
    public var turnID: String
    public var userID: String
    public var githubCredentialGrant: RemoteGithubCredentialGrant?

    public init(turnID: String, userID: String, githubCredentialGrant: RemoteGithubCredentialGrant?) {
        self.turnID = turnID
        self.userID = userID
        self.githubCredentialGrant = githubCredentialGrant
    }
}

/// Personal keys are used only in a workspace that is not shared. When a workspace becomes shared,
/// every process still holding them is stopped.
public enum PersonalCredentials {
    public static let environmentMark = "environment"
    public static let sharedSentence = "This Bloom Cloud workspace was shared, so the turn stopped; the next turn uses the team key."
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

/// No runbloom.app: every turn starts with no grant, and agents use whatever sign-in the machine
/// already has. For tests, and for running the runtime anywhere a person is already the only user.
public struct UngatedTurns: RemoteTurnGate {
    public init() {}
    public func register(
        _ kind: RemoteTurnKind, chat: SessionID?, agent: AgentKind?, model: String?, caller: RemoteCaller
    ) async throws -> String { "" }
    public func start(turnID: String) async throws -> RemoteTurnGrant { RemoteTurnGrant() }
    public func end(turnID: String) async {}
}
