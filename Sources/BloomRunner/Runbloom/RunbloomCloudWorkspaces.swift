import BloomCore
import Foundation

/// `cloud_workspace_start`'s one call: asking runbloom.app to make another Cloud workspace.
///
/// runbloom.app decides everything that matters (the team switch, the limits, whether the person
/// may create there, no chains) and says why in a sentence written for a person, so a refusal is
/// passed to the agent as it came. What is written here is only for what runbloom.app could not
/// say, because it did not answer.
extension RunbloomClient {
    public func stopCloudWorkspace(_ request: CloudWorkspaceStopRequest) async -> CloudWorkspaceStopAnswer {
        do {
            var body: [String: Any] = ["turn_id": request.turnID]
            if let wanted = request.workspace {
                let listed = try await reachableWorkspaces(turnID: request.turnID)
                let byID = listed.first { $0.id == wanted }
                let byName = listed.filter { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
                guard let target = byID ?? (byName.count == 1 ? byName.first : nil) else {
                    if byName.count > 1 {
                        return .refused("More than one workspace is called \(wanted). Use its id: "
                            + byName.map(\.id).joined(separator: ", ") + ".")
                    }
                    return .refused("There is no workspace called \(wanted) that this person can reach. "
                        + "workspace_list says which there are.")
                }
                body["workspace_id"] = target.id
            }
            let data = try await send(.POST, "/cloud-workspaces/archive",
                                      body: JSONSerialization.data(withJSONObject: body), expecting: [202])
            return .requested(try decode(StoppedBody.self, data, status: 202).workspace.stopped)
        } catch RunbloomError.refused(_, _, let message, _, _) {
            return .refused(message)
        } catch {
            return .refused("runbloom.app did not confirm whether the workspace was archived. "
                + "Check it in Bloom before trying again.")
        }
    }

    public func createCloudWorkspace(_ request: CloudWorkspaceRequest) async -> CloudWorkspaceAnswer {
        var body: [String: Any] = [
            "turn_id": request.turnID,
            "name": request.order.name,
            "run_setup": request.order.runSetup,
        ]
        body["branch"] = request.order.branch
        body["base_branch"] = request.order.baseBranch
        body["project"] = request.order.project
        body["prompt"] = request.order.prompt
        if request.order.prompt != nil, let agent = request.agent {
            var controls: [String: Any] = ["agent": agent]
            controls["model"] = request.model
            controls["effort"] = request.effort
            body["controls"] = controls
        }
        do {
            let data = try await send(.POST, "/cloud-workspaces", body: JSONSerialization.data(withJSONObject: body),
                                      headers: ["Idempotency-Key": request.idempotencyKey], expecting: [200, 201])
            return .created(try decode(CreatedBody.self, data, status: 201).workspace.created)
        } catch RunbloomError.refused(_, _, let message, _, _) {
            return .refused(message)
        } catch let error as RunbloomError where error.isWorthRetrying {
            // The key makes asking again safe: a workspace made before the answer was lost is the
            // one handed back, not a second.
            return .refused("runbloom.app could not be reached, so no Bloom Cloud workspace was created. "
                + "Asking again with the same name is safe: it will not make two.")
        } catch {
            return .refused("runbloom.app answered in a way this machine does not understand, so it cannot say "
                + "whether the workspace was created. Ask the person to look in Bloom before trying again.")
        }
    }

    private struct CreatedBody: Decodable {
        struct Workspace: Decodable {
            var id: String
            var name: String
            var state: String
            var url: String
            var created: CloudWorkspaceCreated { CloudWorkspaceCreated(id: id, name: name, state: state, url: url) }
        }
        var workspace: Workspace
    }

    private struct StoppedBody: Decodable {
        struct Workspace: Decodable {
            var id: String
            var name: String
            var state: String
            var stopped: CloudWorkspaceStopped { CloudWorkspaceStopped(id: CloudWorkspaceID(id), name: name, state: state) }
        }
        var workspace: Workspace
    }
}
