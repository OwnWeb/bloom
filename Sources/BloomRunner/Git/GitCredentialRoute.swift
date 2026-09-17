import BloomCore
import Foundation
import HTTPTypes
import Hummingbird

/// `POST /_bloom/local/git-credentials`: a GitHub token for git and gh on this machine.
///
/// **Loopback and a local secret, and never through Caddy.** The machine's URL routes `/_bloom/*`
/// to this server, so Caddy refuses `/_bloom/local/*` outright, and the route itself wants the
/// secret Bloom Runner writes beside its database at start (mode 600, readable by the machine's
/// user). Everyone with a shell on the machine can read that file, which is accepted for the reason
/// the design gives: the machine is the isolation boundary, and what the secret reaches is scoped to
/// this workspace's own repository and to turns people already started.
///
/// **Whose token is decided here, not by the caller.** A chat's agent passes its chat id and a
/// terminal passes its turn id; the server asks the runtime which turn that chat is running now, so
/// a process launched for one person's turn and reused for a teammate's pushes as the teammate.
/// Nothing running means a read-only installation token.
enum GitCredentialRoute {
    static let secretHeader = HTTPField.Name("Bloom-Local-Secret")!

    struct Asked: Codable {
        var repository: String
        var chatID: String?
        var turnID: String?

        enum CodingKeys: String, CodingKey {
            case repository
            case chatID = "chat_id"
            case turnID = "turn_id"
        }
    }

    struct Answer: Codable {
        var username: String
        var token: String
    }

    static func register(on router: Router<WorkspaceRequestContext>, secret: String, repository: String, runtime: WorkspaceRuntime,
                         fetch: @escaping @Sendable (String, RunbloomGitOperation, String?) async throws -> RunbloomGitCredential) {
        router.post("/_bloom/local/git-credentials") { request, _ -> Response in
            guard let given = request.headers[secretHeader], constantTimeEquals(given, secret) else {
                return Response(status: .notFound)
            }
            guard let body = try? await request.body.collect(upTo: 16 * 1_024),
                  let asked = try? JSONDecoder().decode(Asked.self, from: Data(buffer: body)) else {
                return Response(status: .badRequest)
            }
            // Only this workspace's repository, whatever git asked for: a token for anything else
            // would be refused by runbloom.app anyway, and asking costs it a request.
            guard asked.repository.lowercased() == repository.lowercased() else { return Response(status: .forbidden) }
            var turn = asked.turnID
            if turn == nil, let chat = asked.chatID { turn = await runtime.runningTurnID(chat: chat) }
            // runbloom.app answers 503 while GitHub is unreachable, and a clone halfway through setup
            // is worth a few seconds of patience before git is told no.
            var delay = Duration.seconds(1)
            for attempt in 1...4 {
                do {
                    let credential = try await fetch(repository, turn == nil ? .read : .write, turn)
                    return WireResponses.json(Answer(username: credential.username, token: credential.token))
                } catch let error as RunbloomError where error.isWorthRetrying && attempt < 4 {
                    try? await Task.sleep(for: delay)
                    delay *= 2
                } catch {
                    return Response(status: .forbidden)
                }
            }
            return Response(status: .forbidden)
        }
    }

    static func constantTimeEquals(_ left: String, _ right: String) -> Bool {
        let a = Array(left.utf8), b = Array(right.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}
