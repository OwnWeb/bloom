import BloomCore
import Foundation

/// The runtime's turn gate backed by runbloom.app. See `RemoteTurnGate` for why a turn is
/// registered and started in two steps.
///
/// What this adds over `RunbloomClient` is translation into the runtime's own terms: a refusal to
/// register reaches the person who sent the prompt as a `RemoteFailure` with a wire code, and a
/// refusal to start becomes a `RemoteTurnRefusal`, which the queue keeps the prompt for. Anything
/// else thrown from `start` is runbloom.app being unreachable, and the queue pauses with its
/// sentence.
public struct RunbloomTurns: RemoteTurnGate {
    private let client: RunbloomClient
    private let modelGateway: ModelGateway?
    private let modelGatewayBaseURL: String?
    private let modelGatewayUsable: @Sendable () -> Bool
    private let registrations = RunbloomTurnRegistrations()
    private let endAttempts: Int
    private let endRetryDelay: Duration

    /// `endRetryDelay` doubles between attempts. It is a parameter so a test can make it short.
    init(
        client: RunbloomClient, modelGateway: ModelGateway? = nil,
        modelGatewayBaseURL: String? = nil,
        modelGatewayUsable: @escaping @Sendable () -> Bool = { false },
        endAttempts: Int = 4, endRetryDelay: Duration = .milliseconds(500)
    ) {
        self.client = client
        self.modelGateway = modelGateway
        self.modelGatewayBaseURL = modelGatewayBaseURL
        self.modelGatewayUsable = modelGatewayUsable
        self.endAttempts = max(1, endAttempts)
        self.endRetryDelay = endRetryDelay
    }

    public func register(
        _ kind: RemoteTurnKind, chat: SessionID?, agent: AgentKind?, model: String?, caller: RemoteCaller
    ) async throws -> String {
        // Only a person's token can register a turn. The server acting for itself has none, and
        // sending the workspace secret in its place is exactly what runbloom.app is built to refuse.
        guard let token = caller.sessionToken, !token.isEmpty else {
            throw RemoteFailure(.unauthenticated, "Sign in again to send this to the Bloom Cloud workspace.")
        }
        do {
            let id = try await client.registerTurn(
                kind: kind, chatID: chat?.rawValue, agent: agent, model: model, sessionToken: token
            )
            await registrations.record(kind, for: id)
            return id
        } catch RunbloomError.refused(_, let code, let message, _, _) {
            switch code {
            case "missing_ability": throw RemoteFailure(.missingAbility, message)
            case "invalid_session_token": throw RemoteFailure(.unauthenticated, message)
            default: throw RemoteFailure(.invalidValue, message)
            }
        } catch let error as RunbloomError where error.isWorthRetrying {
            throw RemoteFailure(.unavailable, error.description)
        }
    }

    public func start(turnID: String) async throws -> RemoteTurnGrant {
        do {
            let start = try await client.startTurn(turnID)
            let kind = await registrations.kind(for: turnID)
            let agentEnvironments: [AgentKind: [String: String]]
            if start.modelGrants.isEmpty, kind == .terminal {
                agentEnvironments = [:]
            } else {
                guard !start.modelGrants.isEmpty, modelGatewayUsable(),
                      let modelGateway, let modelGatewayBaseURL else {
                    throw RemoteTurnRefusal.refused(
                        code: "model_grant_invalid",
                        message: "The turn has no usable opaque model grant."
                    )
                }
                agentEnvironments = try await modelGateway.install(
                    turnID: turnID, grants: start.modelGrants, baseURL: modelGatewayBaseURL
                )
            }
            return RemoteTurnGrant(
                agentEnvironments: agentEnvironments, environment: start.environment,
                githubCredentialGrant: start.githubCredentialGrant
            )
        } catch RunbloomError.refused(_, "limit_reached", let message, let limit, _) {
            throw RemoteTurnRefusal.blocked(DeliveryBlock(limit: limit ?? "", message: message))
        } catch RunbloomError.refused(let status, let code, let message, _, _) where (400..<500).contains(status) {
            throw RemoteTurnRefusal.refused(code: code, message: message)
        } catch let refusal as ModelGateway.Refusal {
            throw RemoteTurnRefusal.refused(code: "model_grant_invalid", message: refusal.message)
        }
    }

    /// Never throws, because a turn is ending whatever runbloom.app says. It does try more than
    /// once: a turn left running there counts against the team's concurrency and usage until
    /// runbloom.app gives up on it, so one dropped connection should not be enough to leave it.
    /// A refusal (an unknown or already ended turn) is not retried.
    public func end(turnID: String) async {
        await modelGateway?.revoke(turnID: turnID)
        await registrations.remove(turnID)
        var delay = endRetryDelay
        for attempt in 1...endAttempts {
            do {
                try await client.endTurn(turnID)
                return
            } catch let error as RunbloomError where !error.isWorthRetrying {
                return
            } catch {
                guard attempt < endAttempts, !Task.isCancelled else { return }
                try? await Task.sleep(for: delay)
                delay *= 2
            }
        }
    }

    /// A trusted terminal-agent launcher uses this after it has isolated the agent process. The
    /// terminal itself receives neither this environment nor a credential that can call it.
    func issueModelAccess(
        turnID: String, agent: AgentKind, model: String, requestID: UUID
    ) async throws -> [String: String] {
        guard modelGatewayUsable(), let modelGateway, let modelGatewayBaseURL else {
            throw RemoteTurnRefusal.refused(
                code: "model_grant_invalid", message: "The local model gateway is unavailable."
            )
        }
        return try await modelGateway.issue(
            turnID: turnID, agent: agent, model: model, baseURL: modelGatewayBaseURL,
            requestID: requestID
        )
    }
}

private actor RunbloomTurnRegistrations {
    private var kinds: [String: RemoteTurnKind] = [:]

    func record(_ kind: RemoteTurnKind, for id: String) { kinds[id] = kind }
    func kind(for id: String) -> RemoteTurnKind? { kinds[id] }
    func remove(_ id: String) { kinds.removeValue(forKey: id) }
}
