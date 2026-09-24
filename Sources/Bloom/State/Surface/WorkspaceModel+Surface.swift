import Foundation
import SwiftUI
import BloomCore

/// `WorkspaceModel` as the shared views see it: what this workspace is, and its review.
///
/// The protocol was written from what the inspector already asked a workspace for, which is why
/// most of what it needs was already here under the right name: the local path kept every line of
/// its behaviour and gained an interface. The conversations and the column are
/// `WorkspaceModel+Chats`, and the pull request and its checks `WorkspaceModel+PullRequest`; the
/// conformance is declared here because a type conforms in one place.
extension WorkspaceModel: WorkspaceSurface {
    var surfaceID: WorkspaceSurfaceID { .local(workspace.id) }
    var surfaceName: String { workspace.name }
    var surfaceBranch: String { workspace.branch }
    var surfaceBaseBranch: String { workspace.baseBranch }
    var worktreePath: String? { workspace.path }
    var capabilities: WorkspaceCapabilities { .local }
    var openInRepoID: RepoID? { repo?.id }

    /// The review in the centre column, which is where a local workspace has always opened a file.
    func openFile(path: String, focusing: Bool) {
        FileReview.open(path: path, in: self, focusing: focusing)
    }

    var activeReviewPath: String? { FileReview.activePath(in: self) }

    var showsAllFiles: Bool {
        CenterTabStore.shared.review(for: workspace.id)?.showsAllFiles == true
    }

    func showAllFiles(_ shows: Bool) {
        guard let tab = CenterTabStore.shared.review(for: workspace.id) else { return }
        CenterTabStore.shared.setShowsAllFiles(shows, for: tab)
    }

    /// The file on this Mac, with its editor and its preview. An absolute path is a file outside
    /// the worktree, which the review opens read-only.
    func filePane(path: String) -> FilePreview {
        let isAbsolute = path.hasPrefix("/")
        return FilePreview(
            model: self, path: path,
            absolutePathOverride: isAbsolute ? path : nil,
            canEditInBloom: !isAbsolute
        )
    }

    func absolutePath(for relativePath: String) -> String? {
        (workspace.path as NSString).appendingPathComponent(relativePath)
    }

    func deleteFile(path: String) async -> String? {
        let file = URL(fileURLWithPath: workspace.path).appendingPathComponent(path)
        let failure = await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                try FileManager.default.trashItem(at: file, resultingItemURL: nil)
                return nil
            } catch {
                return "Could not move \(path) to the Trash: \(error.localizedDescription)"
            }
        }.value
        guard failure == nil else { return failure }
        await refreshFileTree(force: true)
        await refreshChanges(.requested)
        return nil
    }

    func revert(file: ChangedFile) async -> String? {
        await FileRevert.revert(file: file, in: workspace)
    }

    func discard(hunk: DiffHunk, of file: ChangedFile) async -> String? {
        await FileRevert.discard(hunk: hunk, of: file, in: workspace, scope: diffScope)
    }
}
