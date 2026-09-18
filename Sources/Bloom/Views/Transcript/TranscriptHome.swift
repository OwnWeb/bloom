import BloomCore

/// Where a transcript's file paths point, and which workspace a file chip opens into.
///
/// It replaces the whole `Workspace` these rows used to be handed, and the reason was already
/// written on `TranscriptRowView`'s own `Equatable`: the only two things any row ever read off
/// that value were `id` and `path`, so the other fourteen columns were invalidation surface for
/// nothing.
///
/// Making it this pair is what lets a conversation with no worktree draw the same rows. Ask Bloom
/// has a directory and no workspace, which is exactly this shape; a `Workspace` invented to carry
/// the pair would have needed a project to hang off, and one of those invented too.
///
/// `WorkspaceEventsView` is the case that shows this was overdue. It had no file chips to draw at
/// all, and was building an empty `Workspace` with a blank `RepoID` every pass to satisfy the
/// type.
struct TranscriptHome: Hashable {
    /// The workspace whose panes a file chip opens into. Nil when there is none, and a chip then
    /// draws and previews as it always did but opens nothing, because there is no pane to open it
    /// in.
    var workspaceID: WorkspaceID?
    /// The workspace of either kind this conversation is in, which is what the setup row at the
    /// head of the transcript is drawn for. A Cloud chat has one of these and no `workspaceID`,
    /// because the things that field is for are a worktree's: a file chip to open, a subagent to
    /// run in it. See `WorkspaceEventsView`.
    var surfaceID: WorkspaceSurfaceID?
    /// The directory the paths in this conversation are relative to.
    var worktree: String

    init(workspaceID: WorkspaceID? = nil, surfaceID: WorkspaceSurfaceID? = nil, worktree: String = "") {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID ?? workspaceID.map { .local($0) }
        self.worktree = worktree
    }

    init(_ workspace: Workspace) {
        self.workspaceID = workspace.id
        self.surfaceID = .local(workspace.id)
        self.worktree = workspace.path
    }
}
