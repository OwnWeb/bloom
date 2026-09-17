import BloomCore
import BloomProtocol
import Foundation
import HTTPTypes
import Hummingbird

/// `POST /_bloom/v1/rpc`: one command, answered with one reply.
///
/// A command's own outcome, success or refusal, is a 200 carrying a reply, because the reply is
/// what a client records against its command id. Only what happens before there is a command to
/// answer (no token, a body that is not an envelope) is an HTTP error.
enum RPCRoute {
    static func register(on router: Router<WorkspaceRequestContext>, runtime: WorkspaceRuntime, verifier: TokenVerifier) {
        router.post("/_bloom/v1/rpc") { request, context -> Response in
            let token: WorkspaceToken
            do {
                token = try await verifier.verify(request.bearerToken ?? "", as: .session)
            } catch {
                return WireResponses.failure(error)
            }
            let body: ByteBuffer
            do {
                body = try await request.body.collect(upTo: context.maxUploadSize)
            } catch {
                return WireResponses.failure(WireError(.tooLarge, "This command is larger than 12 MB."), status: .contentTooLarge)
            }
            let command: CommandRequest
            do {
                command = try WireJSON.decode(CommandRequest.self, from: Data(buffer: body))
            } catch {
                return WireResponses.failure(WireError(.invalidRequest, "The body is not a bloom-workspace version 1 command."), status: .badRequest)
            }
            let caller = token.caller(token: request.bearerToken ?? "")
            return WireResponses.json(await runtime.respond(to: command, as: caller))
        }
    }
}
