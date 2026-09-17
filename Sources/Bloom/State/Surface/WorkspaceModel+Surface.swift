import Foundation
import SwiftUI
import BloomCore

/// `WorkspaceModel` as the shared review views see it.
///
/// Every member but these five already existed with the right name and signature, which is the
/// point: the protocol was written from what the inspector already asks a workspace for, so the
/// local path keeps every line of its behaviour and gains an interface.
extension WorkspaceModel: WorkspaceReviewSurface {
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

    func absolutePath(for relativePath: String) -> String? {
        (workspace.path as NSString).appendingPathComponent(relativePath)
    }

    func revert(file: ChangedFile) async -> String? {
        await FileRevert.revert(file: file, in: workspace)
    }

    func openTerminal(in folder: String) {
        FolderTerminalTab.open(folder: folder, in: self)
    }

    /// Nil: the file is on this Mac, and the menu offers the Finder and an editor instead.
    func gitHubURL(forFile relativePath: String?) -> URL? { nil }

    func openPage(path: String, splittingAxis: SplitAxis?) {
        if let axis = splittingAxis {
            BrowserTab.splitFile(path, in: self, axis: axis)
        } else {
            BrowserTab.openFile(path, in: self)
        }
    }
}
