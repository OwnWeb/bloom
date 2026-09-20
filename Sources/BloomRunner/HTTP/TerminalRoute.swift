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
/// shell alone. `BLOOM_TERMINAL` in its environment is what lets `git push` from it push as them:
/// the credential route looks up the turn of whichever connection to that terminal is open now,
/// because a shell outlives its connection and the turn it started with ends with that one.
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

    /// The auth frame's token, verified for this workspace and for a terminal. A function of its
    /// own so the refusals can be tested without a socket: a token for another workspace, an
    /// expired one, a preview token and one without `terminal` all stop here.
    static func authorise(_ raw: String, verifier: TokenVerifier) async throws -> WorkspaceToken {
        let token = try await verifier.verify(raw, as: .session)
        guard token.abilities.contains("view"), token.abilities.contains("terminal") else {
            throw RemoteFailure(.missingAbility, "Your access to this Bloom Cloud workspace does not include the terminal.")
        }
        try token.refuseIfMintedForAnAgent()
        return token
    }

    private static func serve(name: String, inbound: WebSocketInboundStream, outbound: WebSocketOutboundWriter, dependencies: Dependencies) async throws {
        let connections = dependencies.connections
        guard await connections.admitUnauthenticated() else {
            try await outbound.close(.policyViolation, reason: "Too many terminals are connecting. Try again in a moment.")
            return
        }
        var waiting = true
        defer { if waiting { Task { await connections.authenticated() } } }
        var messages = inbound.messages(maxSize: maximumFrame).makeAsyncIterator()
        // Closing the socket is what ends a read that never gets an answer, so the deadline closes
        // it rather than trying to cancel the read.
        let deadline = Task {
            try await Task.sleep(for: authenticationDeadline)
            try await outbound.close(.policyViolation, reason: "Authenticate within five seconds.")
        }
        let first = try await messages.next()
        deadline.cancel()
        waiting = false
        await connections.authenticated()
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
        let personal: Set<String>
        var registered: String?
        do {
            token = try await authorise(raw, verifier: dependencies.verifier)
            let caller = token.caller(token: raw)
            turnID = try await dependencies.gate.register(.terminal, chat: nil, agent: nil, caller: caller)
            registered = turnID
            (environment, personal) = try await shellEnvironment(turnID: turnID, terminal: name, gate: dependencies.gate, runtime: dependencies.runtime)
        } catch {
            // Registered but refused at start: runbloom.app counts a registered turn until it ends.
            if let registered, !registered.isEmpty { Task { await dependencies.gate.end(turnID: registered) } }
            try await outbound.close(.policyViolation, reason: RemoteFailure.wire(error).message)
            return
        }
        defer { if !turnID.isEmpty { Task { await dependencies.gate.end(turnID: turnID) } } }

        let attachment: RemoteTerminalAttachment
        do {
            attachment = try await dependencies.runtime.terminals().attach(name: name, environment: environment, owner: token.author?.userID, personal: personal)
        } catch {
            try await outbound.close(.unexpectedServerError, reason: RemoteFailure.wire(error).message)
            return
        }
        let expiry = TerminalExpiry(expiresAt: token.expiresAt)
        let connection = await dependencies.connections.add(userID: token.author?.userID, turnID: turnID, terminal: name) {
            await attachment.close()
        }
        defer { Task { await dependencies.connections.remove(connection) } }
        // A revoke that landed during the two runbloom.app calls above found no socket to close.
        if await dependencies.verifier.revocations.isRevoked(token.subject, issuedAt: token.issuedAt) {
            await attachment.close()
            try await outbound.close(.policyViolation, reason: "Your access to this Bloom Cloud workspace was removed.")
            return
        }

        // Output and the token's deadline run beside the socket's own reads, which stay in this
        // task because the inbound iterator cannot be handed to another one.
        let output = Task {
            for await chunk in attachment.output {
                try await outbound.write(.binary(ByteBuffer(bytes: chunk)))
            }
            try await outbound.close(.normalClosure, reason: nil)
        }
        let tokenDeadline = Task {
            try await closeAtExpiry(expiry) {
                try await outbound.close(.policyViolation, reason: "token_expired")
                await attachment.close()
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
                    // The same person, and still allowed the terminal: a renewal must not carry a
                    // shell past the moment its owner's access narrowed.
                    guard let fresh = try? await dependencies.verifier.verify(raw, as: .session),
                          fresh.author?.userID == token.author?.userID,
                          fresh.abilities.contains("view"), fresh.abilities.contains("terminal"),
                          fresh.actor == nil else { continue }
                    await expiry.extend(to: fresh.expiresAt)
                case .auth: continue
                }
            }
        }
        await attachment.close()
    }

    /// The shell's environment: every key runbloom.app resolved for this person, under the names
    /// each CLI reads, their personal environment, and the turn git credentials are asked for.
    /// Also answers what of it is one person's own, which the shell is tagged with, and retires
    /// whatever this grant shows can no longer hold personal credentials.
    static func shellEnvironment(
        turnID: String, terminal: String, gate: any RemoteTurnGate, runtime: WorkspaceRuntime
    ) async throws -> (environment: [String: String], personal: Set<String>) {
        var environment: [String: String] = [:]
        guard !turnID.isEmpty else { return (environment, []) }
        let grant = try await gate.start(turnID: turnID)
        await runtime.retirePersonalCredentials(where: grant.supersedes)
        for agent in grant.agentKeys.keys {
            environment.merge(grant.environment(for: agent)) { _, new in new }
        }
        environment.merge(grant.environment) { current, _ in current }
        environment["BLOOM_TERMINAL"] = terminal
        return (environment, grant.personalMarks(for: Array(grant.agentKeys.keys)))
    }
}

extension TerminalRoute {
    /// **A terminal does not outlive its token.** Waits for `expiry`, which a `reauth` with a fresh
    /// token of the same person moves on, and closes the socket when it passes. A person removed
    /// from the team gets no fresh token from runbloom.app, so a shell they had open closes within
    /// five minutes even if the `revoke` call never arrives. Checked at least every thirty seconds,
    /// so a deadline moved earlier is not overslept.
    static func closeAtExpiry(_ expiry: TerminalExpiry, close: @Sendable () async throws -> Void) async throws {
        while !Task.isCancelled {
            let wait = await expiry.expiresAt.timeIntervalSinceNow
            if wait <= 0 {
                try await close()
                return
            }
            try await Task.sleep(for: .seconds(min(wait, 30)))
        }
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

    /// **How many sockets may be waiting to authenticate at once.** The upgrade happens before the
    /// token is read, so without a cap anybody could hold hundreds of sockets for their five
    /// seconds each (L4 in the review of 19 September 2026). A socket over it is closed at once.
    static let unauthenticatedLimit = 32
    private var unauthenticated = 0

    /// Takes a place among the sockets waiting to authenticate, or answers false when they are full.
    func admitUnauthenticated() -> Bool {
        guard unauthenticated < Self.unauthenticatedLimit else { return false }
        unauthenticated += 1
        return true
    }

    /// Gives the place back, whether the socket authenticated, was refused or went away.
    func authenticated() {
        unauthenticated = max(0, unauthenticated - 1)
    }

    private var entries: [UUID: (userID: String?, turnID: String, terminal: String, close: @Sendable () async -> Void)] = [:]

    func add(userID: String?, turnID: String = "", terminal: String = "", close: @escaping @Sendable () async -> Void) -> UUID {
        let id = UUID()
        entries[id] = (userID, turnID, terminal, close)
        return id
    }

    /// The runbloom.app turn of a connection to this terminal that is open now, if any. A terminal
    /// belongs to one person, so any of its connections is theirs.
    func liveTurn(terminal: String) -> String? {
        guard !terminal.isEmpty else { return nil }
        return entries.values.first { $0.terminal == terminal && !$0.turnID.isEmpty }?.turnID
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
