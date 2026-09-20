import AsyncHTTPClient
import BloomCore
import BloomProtocol
import Foundation
import NIOCore

/// The team's other Bloom Cloud workspaces, reached the way a client reaches one.
///
/// **runbloom.app is the authority and never the pipe.** It lists the workspaces the turn's person
/// may open and mints a five-minute session token for one of them, for that person, with `view` and
/// `prompt` and nothing more, carrying the signed `act` claim that names this workspace. This
/// machine then speaks the ordinary protocol to the other machine at its own address, and runbloom.app
/// never sees what is said. The other machine verifies that token exactly as it verifies any
/// client's, so everything the authentication audit proves holds here with nothing added: another
/// team's workspace, a removed member and a share guest are refused where the token is minted, and
/// a token for the wrong machine is refused where it lands. See docs/CLOUD-PARITY.md.
enum RunbloomPeers {
    static func peers(client: RunbloomClient, http: HTTPClient) -> WorkspacePeers {
        WorkspacePeers(
            list: { turnID in
                do {
                    return .listed(try await client.reachableWorkspaces(turnID: turnID).filter { !$0.isSelf }.map(\.peer))
                } catch {
                    return .refused(sentence(for: error))
                }
            },
            say: { message in
                do {
                    return try await say(message, client: client, http: http)
                } catch {
                    return .refused(sentence(for: error))
                }
            },
            depositForMac: { deposit in await depositForMac(deposit, client: client) }
        )
    }

    /// `POST .../mac-messages`, asked again with the same key while runbloom.app cannot be reached, so
    /// a lost answer queues the message once. runbloom.app's own sentence for a refusal is passed on
    /// as it stands, with how long to wait added for the hourly limit, which its sentence leaves out.
    static func depositForMac(_ deposit: MacDeposit, client: RunbloomClient,
                              pause: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) async -> MacSayAnswer {
        var delay = Duration.seconds(1)
        for attempt in 1...3 {
            do {
                return .queued(expiresAt: try await client.depositMacMessage(deposit))
            } catch let RunbloomError.refused(_, code, message, _, retryAfter) {
                guard code == "too_many_requests", let retryAfter, retryAfter > 0 else { return .refused(message) }
                let minutes = max(1, Int((Double(retryAfter) / 60).rounded(.up)))
                return .refused(message + " Try again in \(minutes) minute\(minutes == 1 ? "" : "s").")
            } catch let error as RunbloomError where error.isWorthRetrying && attempt < 3 {
                await pause(delay)
                delay *= 2
            } catch {
                return .refused("runbloom.app could not be reached, so nothing was queued for their Mac. "
                    + "Sending it again is safe: it will not arrive twice.")
            }
        }
        return .refused("runbloom.app could not be reached, so nothing was queued for their Mac. "
            + "Sending it again is safe: it will not arrive twice.")
    }

    /// Mint, pick the chat, send. A name is matched against the list rather than guessed, so a
    /// workspace the person cannot open is "no such workspace", the same answer runbloom.app gives.
    static func say(_ message: PeerMessage, client: RunbloomClient, http: HTTPClient) async throws -> PeerSayAnswer {
        let listed = try await client.reachableWorkspaces(turnID: message.turnID).filter { !$0.isSelf }
        let wanted = message.workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        let byID = listed.first { $0.id == wanted }
        let byName = listed.filter { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
        guard let target = byID ?? (byName.count == 1 ? byName.first : nil) else {
            if byName.count > 1 {
                return .refused("More than one workspace is called \(wanted). Use its id: "
                    + byName.map(\.id).joined(separator: ", ") + ".")
            }
            return .refused("There is no workspace called \(wanted) that this person can reach. workspace_list says which there are.")
        }
        let minted = try await client.mintToken(turnID: message.turnID, workspaceID: target.id)
        let peer = PeerMachine(address: minted.address, token: minted.token, http: http)

        guard case .workspace(let snapshot) = try await peer.perform(.workspace) else {
            throw RunbloomError.unexpected(status: 200)
        }
        let chat: ChatRecord
        if let named = message.chat?.trimmingCharacters(in: .whitespacesAndNewlines), !named.isEmpty {
            guard let found = snapshot.chats.first(where: { $0.id == named || $0.title == named }) else {
                return .refused("\(target.name) has no chat called \(named). Leave 'chat' out for its most recent one.")
            }
            chat = found
        } else if let recent = snapshot.chats.filter({ $0.parentChatID == nil }).max(by: { $0.updatedAt < $1.updatedAt }) {
            // A crew member's chat belongs to the agent that started it, never to a message from outside.
            chat = recent
        } else {
            guard case .chat(let made) = try await peer.perform(.newChat(controls: snapshot.composerDefaults)) else {
                throw RunbloomError.unexpected(status: 200)
            }
            chat = made
        }
        let answer = try await peer.perform(.send(chatID: chat.id, text: message.text, via: message.via.record))
        if case .queued = answer { return .sent(workspace: target.name, chat: chat.title, queued: true) }
        return .sent(workspace: target.name, chat: chat.title, queued: false)
    }

    /// runbloom.app's own sentence when it refused, the other machine's when that refused, and a
    /// plain one otherwise. Never a token, a URL with a secret in it or a response body.
    static func sentence(for error: Error) -> String {
        switch error {
        case RunbloomError.refused(_, _, let message, _, _): message
        case let failure as PeerMachine.Refusal: failure.message
        case let failure as RunbloomError where failure.isWorthRetrying:
            "runbloom.app could not be reached, so nothing was sent. Try again in a moment."
        default:
            "The other workspace answered in a way this machine does not understand, so it cannot say whether the message arrived."
        }
    }
}

/// One other machine, for the life of one token.
struct PeerMachine {
    struct Refusal: Error { var message: String }

    let address: String
    let token: String
    let http: HTTPClient

    func perform(_ operation: WorkspaceOperation) async throws -> OperationResult {
        let base = address.hasSuffix("/") ? String(address.dropLast()) : address
        var request = HTTPClientRequest(url: base + "/_bloom/v1/rpc")
        request.method = .POST
        request.headers.add(name: "Authorization", value: "Bearer \(token)")
        request.headers.add(name: "Content-Type", value: "application/json")
        request.body = .bytes(ByteBuffer(bytes: try WireJSON.encode(CommandRequest(operation))))
        let response = try await http.execute(request, timeout: .seconds(30))
        let body = Data(try await response.body.collect(upTo: 8 << 20).readableBytesView)
        let reply: CommandReply
        do {
            reply = try WireJSON.decode(CommandReply.self, from: body)
        } catch {
            // A 401 from the other machine comes as the failure object alone, not a reply.
            if let failure = try? JSONDecoder().decode(WireError.self, from: body) { throw Refusal(message: failure.message) }
            throw RunbloomError.unexpected(status: Int(response.status.code))
        }
        if let error = reply.error { throw Refusal(message: error.message) }
        guard let result = reply.result else { throw RunbloomError.unexpected(status: Int(response.status.code)) }
        return result
    }
}

/// A workspace runbloom.app lists for the turn's person.
struct ReachableWorkspace: Decodable, Sendable {
    var id: String
    var name: String
    var state: String
    var isSelf: Bool

    var peer: PeerWorkspace { PeerWorkspace(id: id, name: name, state: state) }

    enum CodingKeys: String, CodingKey {
        case id, name, state
        case isSelf = "is_self"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        isSelf = try c.decodeIfPresent(Bool.self, forKey: .isSelf) ?? false
    }
}

struct MintedToken: Sendable {
    var token: String
    var address: String
}

extension RunbloomClient {
    func reachableWorkspaces(turnID: String) async throws -> [ReachableWorkspace] {
        struct Answer: Decodable { var workspaces: [ReachableWorkspace] }
        let turn = turnID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? turnID
        let data = try await send(.GET, "/workspaces?turn_id=\(turn)", expecting: [200])
        return try decode(Answer.self, data, status: 200).workspaces
    }

    /// Leaves a message for the turn's person's Mac. Answers when runbloom.app drops it uncollected.
    func depositMacMessage(_ deposit: MacDeposit) async throws -> String? {
        struct Answer: Decodable {
            var expiresAt: String?
            enum CodingKeys: String, CodingKey { case expiresAt = "expires_at" }
        }
        var body: [String: Any] = ["turn_id": deposit.turnID, "target_workspace": deposit.workspace, "text": deposit.text]
        if let chat = deposit.chat { body["via"] = ["chat": String(chat.prefix(255))] }
        let data = try await send(.POST, "/mac-messages", body: JSONSerialization.data(withJSONObject: body),
                                  headers: ["Idempotency-Key": deposit.idempotencyKey], expecting: [200, 202])
        return try decode(Answer.self, data, status: 202).expiresAt
    }

    /// A session token for another workspace, for the turn's person, with `view` and `prompt`.
    func mintToken(turnID: String, workspaceID: String) async throws -> MintedToken {
        struct Answer: Decodable {
            struct Target: Decodable { var address: String }
            var token: String
            var workspace: Target
        }
        let body: [String: Any] = ["turn_id": turnID, "workspace_id": workspaceID, "abilities": ["view", "prompt"]]
        let data = try await send(.POST, "/tokens", body: JSONSerialization.data(withJSONObject: body), expecting: [200, 201])
        let answer = try decode(Answer.self, data, status: 201)
        return MintedToken(token: answer.token, address: answer.workspace.address)
    }
}
