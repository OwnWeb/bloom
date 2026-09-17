import BloomCore
import BloomProtocol
import Foundation
import HTTPTypes
import Hummingbird

/// What runbloom.app can ask of the machine, with a control token only it can sign.
public protocol MachineControl: Sendable {
    /// A limit was reached while awake: stop turns, block the queue, report, and let go.
    func stop(limit: String) async
    /// A limit lifted: try the blocked prompts again.
    func limitsCleared() async
    /// Somebody lost access: close everything of theirs now.
    func revoke(userID: String) async
    /// Move to another bloom-server release.
    func update(version: String, sha256: String) async throws
    /// Team or project environment changed: fetch it again.
    func environmentChanged() async
}

/// `POST /_bloom/v1/control/{stop, limits-cleared, revoke, update, environment}`.
///
/// **Only a control token reaches these, and only these take one.** runbloom.app keeps the workspace
/// secret hashed and so cannot use it here; it signs a token instead, sixty seconds long, for this
/// workspace alone, and the verifier refuses a replay. Any 2xx is accepted on runbloom.app's side,
/// so each answers 202 once the work is under way rather than keeping runbloom.app waiting on it.
enum ControlRoutes {
    private struct Stop: Decodable { var limit: String }
    private struct Revoke: Decodable {
        var userID: String
        enum CodingKeys: String, CodingKey { case userID = "user_id" }
    }
    private struct Update: Decodable {
        var version: String
        var sha256: String
    }

    static func register(on router: Router<WorkspaceRequestContext>, verifier: TokenVerifier, control: any MachineControl) {
        router.post("/_bloom/v1/control/:action") { request, context -> Response in
            do {
                _ = try await verifier.verify(request.bearerToken ?? "", as: .control)
            } catch {
                return WireResponses.failure(error)
            }
            let body = Data(buffer: (try? await request.body.collect(upTo: 64 * 1_024)) ?? ByteBuffer())
            do {
                switch context.parameters.get("action") {
                case "stop":
                    let stop = try JSONDecoder().decode(Stop.self, from: body)
                    Task { await control.stop(limit: stop.limit) }
                case "limits-cleared":
                    Task { await control.limitsCleared() }
                case "revoke":
                    let revoke = try JSONDecoder().decode(Revoke.self, from: body)
                    await control.revoke(userID: revoke.userID)
                case "update":
                    let update = try JSONDecoder().decode(Update.self, from: body)
                    try await control.update(version: update.version, sha256: update.sha256)
                case "environment":
                    Task { await control.environmentChanged() }
                default:
                    return WireResponses.failure(WireError(.notFound, "There is no such control call."), status: .notFound)
                }
            } catch let error as DecodingError {
                return WireResponses.failure(WireError(.invalidRequest, "The control call's body is not what it should be: \(error)"), status: .badRequest)
            } catch {
                return WireResponses.failure(error)
            }
            return Response(status: .accepted)
        }
    }
}
