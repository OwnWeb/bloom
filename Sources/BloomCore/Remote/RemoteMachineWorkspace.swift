import Foundation

/// The one workspace row a machine's database holds, made the first time Bloom Runner starts.
///
/// **Its id is runbloom.app's.** The workspace has one identity everywhere: the id in the token's
/// audience, in every summary and in this row are the same lowercase ULID, so nothing on the
/// machine ever maps one id to another. The repository and the worktree are one directory, because
/// a machine clones the repository for this workspace alone and has no main checkout to share.
///
/// A row that already exists is returned as it is, name and all: the machine owns the name after
/// creation, and a rename done here must survive the server restarting and reading the bootstrap
/// configuration again.
public enum RemoteMachineWorkspace {
    public static func ensure(
        store: Store, id: String, name: String, repository: String, path: String, branch: String, baseBranch: String
    ) async throws -> Workspace {
        let workspaceID = WorkspaceID(id)
        if let existing = try await store.workspace(id: workspaceID) { return existing }
        let repo: Repo
        if let existing = try await store.repo(path: path) {
            repo = existing
        } else {
            repo = try await store.upsert(Repo(name: repository, path: path, defaultBranch: baseBranch))
        }
        let workspace = Workspace(
            id: workspaceID, repoID: repo.id, name: name.isEmpty ? branch : name, branch: branch, path: path, baseBranch: baseBranch
        )
        return try await store.upsert(workspace)
    }
}
