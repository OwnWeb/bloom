import SwiftUI
import BloomCore

/// The part of an inspector row's context menu that hands a path to something else: Open in,
/// Reveal in Finder, a terminal or a page where one applies, and Copy path.
///
/// Three rows drew it, the changed files list, the changed files tree's folders and the worktree
/// tree, each with its own `copyPath()` two lines long. They share a pane, and the comments above
/// each copy were already arguing that the three must not name or order one action differently,
/// which is an argument for one view rather than three copies kept in step by hand. The folder row
/// had in fact put Reveal in Finder above Open in while the other two put it below; it follows
/// them now.
///
/// Everything here is values and closures, so a row that holds these as parameters keeps comparing
/// on its values alone. See `ChangedFileRow.==`.
struct FileLocationMenuItems: View {
    var path: String?
    /// Why the items above Copy path are off, when they are.
    var unavailable: String?
    /// The honest equivalent where the file is not on this Mac: the same file on GitHub.
    var onOpenOnGitHub: (@MainActor () -> Void)?
    /// The row's path inside the worktree, which is what Copy path puts on the pasteboard: the
    /// form a reader pastes into a prompt or a commit message.
    var relativePath: String
    var isDirectory: Bool
    /// False where the row is a historical or index snapshot of the file rather than today's copy
    /// of it, which nothing should be opening. Only Copy path is offered then. See
    /// `DiffScope.allowsWorktreeActions`.
    var allowsWorktreeActions = true
    /// Opens a shell in this folder. Nil for a row that never offers one. See `FolderTerminal`.
    var onOpenTerminal: (() -> Void)?
    /// Opens this file as a page, and in the half a split opens. Nil for a row that never offers
    /// one. See `LocalPageItems`.
    var onOpenPage: (@MainActor () -> Void)?
    var onSplitPage: (@MainActor (SplitAxis) -> Void)?

    var body: some View {
        if let onOpenOnGitHub {
            Button(isDirectory ? "Open Folder on GitHub" : "Open File on GitHub", action: onOpenOnGitHub)
        }
        if allowsWorktreeActions, let path {
            // The target is decided per row rather than per view, because the worktree tree is
            // the one place a row is either kind: a folder is not offered to something that only
            // opens files, and a file is not handed to a terminal.
            OpenInItems(target: isDirectory ? .folder(path) : .file(path))
            Button("Reveal in Finder") { Reveal.inFinder(path) }
            // With the two above rather than beside Copy path: all of these hand the row to
            // something that opens it, and only the last item is about the clipboard. Worded as
            // `FolderTerminal` words it in every tree, because the trees share a pane and must not
            // name one action two ways. `canOpen` is what keeps it off a file row, where the
            // submenu above turns into Open File in, and off a folder that is not on disk, which
            // in the changed files tree is a directory git reports out of a diff after the agent
            // deleted it.
            if let onOpenTerminal, FolderTerminal.canOpen(folder: path) {
                Button(FolderTerminal.menuTitle, action: onOpenTerminal)
            }
            // The other half of that pair, and the same argument for where it sits. The two are
            // never both drawn: a shell wants a folder and a page is a file.
            if let onOpenPage, let onSplitPage {
                LocalPageItems(path: path, open: onOpenPage, split: onSplitPage)
            }
        }
        if allowsWorktreeActions, path == nil, let unavailable {
            // The same items a local workspace offers, in the same order, greyed, saying why.
            Group {
                Button("Reveal in Finder") {}
                Button(FolderTerminal.menuTitle) {}
            }
            .disabled(true)
            .help(unavailable)
        }
        Button("Copy path") { Clipboard.copy(relativePath) }
    }
}
