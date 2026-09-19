import BloomClient
import BloomCore
import BloomProtocol
import Foundation

/// The app's half of `CloudWorkspaceReach`: the Bloom Cloud workspaces the signed-in person can
/// open, and the machine calls the bridge tools make on them.
///
/// **Only what runbloom.app lists for this person, and only what they can open.** A workspace a
/// team owner can see but not open, or one being archived, is not offered, so a name that means
/// one is "no such workspace" rather than a refusal from its machine.
///
/// **Through the connection the window already uses, as the person.** A workspace that is open here
/// is asked on its own connection. One that is not is opened for the call and closed after it,
/// which wakes a sleeping machine: that is the machine's rule for anybody doing anything there,
/// and a reader that did not wake it would have nothing to read.
extension AppModel {
    func cloudWorkspaceReach() -> CloudWorkspaceReach {
        CloudWorkspaceReach(
            workspaces: { [weak self] in await self?.reachableCloudWorkspaces() ?? [] },
            chats: { [weak self] id in
                guard let self else { return .failure(Self.notReady) }
                return await self.cloudChats(id)
            },
            transcript: { [weak self] id, chat, after, limit in
                guard let self else { return .failure(Self.notReady) }
                return await self.cloudTranscript(id, chat: chat, after: after, limit: limit)
            },
            send: { [weak self] id, chat, text, via in
                guard let self else { return .failure(Self.notReady) }
                return await self.cloudSend(id, chat: chat, text: text, via: via)
            },
            changes: { [weak self] id in
                guard let self else { return .failure(Self.notReady) }
                return await self.cloudChanges(id)
            },
            patch: { [weak self] id, path in
                guard let self else { return .failure(Self.notReady) }
                return await self.cloudPatch(id, path: path)
            }
        )
    }

    private nonisolated static var notReady: CloudReachTrouble { CloudReachTrouble("Bloom is still starting up.") }

    private func reachableCloudWorkspaces() -> [CloudWorkspaceTarget] {
        cloud.items
            .filter { $0.canOpen && $0.archivedAt == nil && $0.state != "archiving" && $0.state != "archived" }
            .map {
                CloudWorkspaceTarget(
                    id: $0.id, name: $0.displayName, state: $0.state,
                    repository: $0.project?.repository ?? "", branch: $0.branch
                )
            }
    }

    /// One call on a workspace's machine, on the connection the window has or on one opened for
    /// it. Refused for anything `reachableCloudWorkspaces` does not list, whatever id was passed.
    private func performInCloud(_ id: String, _ operation: WorkspaceOperation) async -> Result<OperationResult, CloudReachTrouble> {
        guard reachableCloudWorkspaces().contains(where: { $0.id == id }) else {
            return .failure(CloudReachTrouble("That Bloom Cloud workspace is not one this account can open."))
        }
        let key = CloudWorkspaceID(id)
        let existing = cloud.existingSession(for: key)
        let session = existing ?? cloud.session(for: key)
        // Closed again only if the person has not opened it in the window meanwhile, which would
        // be closing their workspace under them.
        defer { if existing == nil, selection != .cloud(key) { cloud.close(key) } }
        do {
            return .success(try await session.perform(operation))
        } catch {
            return .failure(CloudReachTrouble(error.message))
        }
    }

    private static func unexpected(_ what: String) -> CloudReachTrouble {
        CloudReachTrouble("The machine answered with something other than \(what).")
    }

    private func cloudChats(_ id: String) async -> Result<[CloudChatSummary], CloudReachTrouble> {
        switch await performInCloud(id, .workspace) {
        case .failure(let trouble): return .failure(trouble)
        case .success(.workspace(let snapshot)):
            return .success(snapshot.chats.map {
                CloudChatSummary(
                    id: $0.id, title: $0.title, agent: $0.agent, state: $0.state,
                    parentChatID: $0.parentChatID, lastSeq: $0.lastSeq, updatedAt: $0.updatedAt
                )
            })
        case .success: return .failure(Self.unexpected("its chats"))
        }
    }

    private func cloudTranscript(
        _ id: String, chat: String, after: Int, limit: Int
    ) async -> Result<(messages: [Message], hasMore: Bool), CloudReachTrouble> {
        switch await performInCloud(id, .transcript(chatID: chat, afterSeq: after, limit: limit)) {
        case .failure(let trouble): return .failure(trouble)
        case .success(.transcript(let record)):
            return .success((record.messages.map { Message(cloudMessage: $0, id: $0.cursor) }, record.hasMore))
        case .success: return .failure(Self.unexpected("the chat"))
        }
    }

    /// An older machine ignores `via` and the message arrives unlabelled, which is the worst it
    /// can do: nothing is refused for carrying it.
    private func cloudSend(_ id: String, chat: String, text: String, via: MessageVia?) async -> Result<Bool, CloudReachTrouble> {
        switch await performInCloud(id, .send(chatID: chat, text: text, via: via?.record)) {
        case .failure(let trouble): return .failure(trouble)
        case .success(.queued): return .success(false)
        case .success: return .success(true)
        }
    }

    private func cloudChanges(_ id: String) async -> Result<CloudWorkspaceChanges, CloudReachTrouble> {
        let workspace: WorkspaceRecord
        switch await performInCloud(id, .workspace) {
        case .failure(let trouble): return .failure(trouble)
        case .success(.workspace(let snapshot)): workspace = snapshot.workspace
        case .success: return .failure(Self.unexpected("the workspace"))
        }
        switch await performInCloud(id, .reviewSnapshot(scope: .branch, knownRevision: nil, wait: false)) {
        case .failure(let trouble): return .failure(trouble)
        case .success(.reviewSnapshot(let snapshot)):
            return .success(CloudWorkspaceChanges(
                branch: workspace.branch, baseBranch: workspace.baseBranch,
                files: (snapshot.files ?? []).map(ChangedFile.init(cloudRecord:))
            ))
        case .success: return .failure(Self.unexpected("its changes"))
        }
    }

    private func cloudPatch(_ id: String, path: String) async -> Result<String, CloudReachTrouble> {
        switch await performInCloud(id, .reviewPatch(path: path, scope: .branch, knownRevision: nil)) {
        case .failure(let trouble): return .failure(trouble)
        case .success(.reviewPatch(let patch)): return .success(patch.patch ?? "")
        case .success: return .failure(Self.unexpected("the diff"))
        }
    }
}
