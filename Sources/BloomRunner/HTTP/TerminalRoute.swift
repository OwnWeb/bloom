import BloomCore
import BloomProtocol
import Foundation
import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// `GET /_bloom/v1/terminal?name=`: a terminal over a WebSocket.
///
/// **The token is the first text frame, not a header,** because a browser's `WebSocket` cannot send
/// one, and every client does the same so there is one path to test. A connection that has not
/// authenticated within five seconds is closed. Output and keystrokes are binary frames; `resize`
/// and `reauth` are text frames. See `TerminalControlFrame`.
///
/// **The shell is a turn.** It is registered with runbloom.app under the person's token and
/// started, which hands the machine that person's agent keys and personal environment for this
/// shell alone, and `BLOOM_TURN_ID` in its environment is what lets `git push` from it push as them.
enum TerminalRoute {
    static let authenticationDeadline: Duration = .seconds(5)
    static let maximumFrame = 1 << 20

    struct Dependencies: Sendable {
        let runtime: WorkspaceRuntime
        let verifier: TokenVerifier
        let gate: any RemoteTurnGate
        let connections: TerminalConnections
    }

    static func register(on router: Router<WorkspaceRequestContext>, dependencies: Dependencies) {
        router.ws("/_bloom/v1/terminal") { request, _ in
            guard let name = request.uri.queryParameters.get("name"), RemoteTerminals.isValid(name: name) else { return .dontUpgrade }
            return .upgrade([:])
        } onUpgrade: { inbound, outbound, context in
            guard let name = context.request.uri.queryParameters.get("name") else { return }
            try await serve(name: name, inbound: inbound, outbound: outbound, dependencies: dependencies)
        }
    }

    private static func serve(name: String, inbound: WebSocketInboundStream, outbound: WebSocketOutboundWriter, dependencies: Dependencies) async throws {
        var messages = inbound.messages(maxSize: maximumFrame).makeAsyncIterator()
        // Closing the socket is what ends a read that never gets an answer, so the deadline closes
        // it rather than trying to cancel the read.
        let deadline = Task {
            try await Task.sleep(for: authenticationDeadline)
            try await outbound.close(.policyViolation, reason: "Authenticate within five seconds.")
        }
        let first = try await messages.next()
        deadline.cancel()
        guard let first else {
            try await outbound.close(.policyViolation, reason: "Send an auth frame first.")
            return
        }
        guard case .text(let text) = first,
              let frame = try? WireJSON.decode(TerminalControlFrame.self, from: Data(text.utf8)),
              case .auth(let raw) = frame else {
            try await outbound.close(.policyViolation, reason: "Send an auth frame first.")
            return
        }
        let token: WorkspaceToken
        let turnID: String
        let environment: [String: String]
        var registered: String?
        do {
            token = try await dependencies.verifier.verify(raw, as: .session)
            guard token.abilities.contains("view"), token.abilities.contains("terminal") else {
                throw RemoteFailure(.missingAbility, "Your access to this Cloud workspace does not include the terminal.")
            }
            let caller = token.caller(token: raw)
            turnID = try await dependencies.gate.register(.terminal, chat: nil, agent: nil, caller: caller)
            registered = turnID
            environment = try await shellEnvironment(turnID: turnID, gate: dependencies.gate)
        } catch {
            // Registered but refused at start: runbloom.app counts a registered turn until it ends.
            if let registered, !registered.isEmpty { Task { await dependencies.gate.end(turnID: registered) } }
            try await outbound.close(.policyViolation, reason: RemoteFailure.wire(error).message)
            return
        }
        defer { if !turnID.isEmpty { Task { await dependencies.gate.end(turnID: turnID) } } }

        let attachment: RemoteTerminalAttachment
        do {
            attachment = try await dependencies.runtime.terminals().attach(name: name, environment: environment)
        } catch {
            try await outbound.close(.unexpectedServerError, reason: RemoteFailure.wire(error).message)
            return
        }
        let expiry = TerminalExpiry(expiresAt: token.expiresAt)
        let connection = await dependencies.connections.add(userID: token.author?.userID) {
            await attachment.close()
        }
        defer { Task { await dependencies.connections.remove(connection) } }

        // Output and the token's deadline run beside the socket's own reads, which stay in this
        // task because the inbound iterator cannot be handed to another one.
        let output = Task {
            for await chunk in attachment.output {
                try await outbound.write(.binary(ByteBuffer(bytes: chunk)))
            }
            try await outbound.close(.normalClosure, reason: nil)
        }
        let tokenDeadline = Task {
            while !Task.isCancelled {
                let wait = await expiry.expiresAt.timeIntervalSinceNow
                if wait <= 0 {
                    try await outbound.close(.policyViolation, reason: "token_expired")
                    await attachment.close()
                    return
                }
                try await Task.sleep(for: .seconds(min(wait, 30)))
            }
        }
        defer {
            output.cancel()
            tokenDeadline.cancel()
        }
        var lastInputNoted = Date.distantPast
        while let message = try await messages.next() {
            switch message {
            case .binary(let buffer):
                await attachment.write(Data(buffer: buffer))
                // A keystroke is human input for the presence lease, noted at most every ten
                // seconds so typing does not turn into a stream of actor hops.
                if let author = token.author, Date().timeIntervalSince(lastInputNoted) > 10 {
                    lastInputNoted = Date()
                    await dependencies.runtime.noteHumanInput(from: author)
                }
            case .text(let text):
                guard let frame = try? WireJSON.decode(TerminalControlFrame.self, from: Data(text.utf8)) else { continue }
                switch frame {
                case .resize(let columns, let rows): await attachment.resize(columns: columns, rows: rows)
                case .reauth(let raw):
                    guard let fresh = try? await dependencies.verifier.verify(raw, as: .session),
                          fresh.author?.userID == token.author?.userID else { continue }
                    await expiry.extend(to: fresh.expiresAt)
                case .auth: continue
                }
            }
        }
        await attachment.close()
    }

    /// The shell's environment: every key runbloom.app resolved for this person, under the names
    /// each CLI reads, their personal environment, and the turn git credentials are asked for.
    static func shellEnvironment(turnID: String, gate: any RemoteTurnGate) async throws -> [String: String] {
        var environment: [String: String] = [:]
        guard !turnID.isEmpty else { return environment }
        let grant = try await gate.start(turnID: turnID)
        for agent in grant.agentKeys.keys {
            environment.merge(grant.environment(for: agent)) { _, new in new }
        }
        environment.merge(grant.environment) { current, _ in current }
        environment["BLOOM_TURN_ID"] = turnID
        return environment
    }
}

/// A terminal token's lifetime, moved on by `reauth`.
actor TerminalExpiry {
    private(set) var expiresAt: Date

    init(expiresAt: Date) { self.expiresAt = expiresAt }

    func extend(to date: Date) { expiresAt = max(expiresAt, date) }
}

/// Open terminal connections by person, so revoking somebody closes their shells' connections.
public actor TerminalConnections {
    public init() {}

    private var entries: [UUID: (userID: String?, close: @Sendable () async -> Void)] = [:]

    func add(userID: String?, close: @escaping @Sendable () async -> Void) -> UUID {
        let id = UUID()
        entries[id] = (userID, close)
        return id
    }

    func remove(_ id: UUID) {
        entries.removeValue(forKey: id)
    }

    func revoke(userID: String) async {
        let closing = entries.filter { $0.value.userID == userID }
        for (id, entry) in closing {
            entries.removeValue(forKey: id)
            await entry.close()
        }
    }

    /// Every terminal socket, at shutdown. An open WebSocket is a request that never finishes, and
    /// the HTTP server's graceful shutdown waits for those.
    func closeAll() async {
        let closing = entries
        entries.removeAll()
        for entry in closing.values { await entry.close() }
    }

    var count: Int { entries.count }
}
