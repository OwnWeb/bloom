import SwiftUI
import BloomCore

/// One workspace in the source list, with everything that surrounds it.
///
/// The drawing is `WorkspaceRow`'s and stays a pure function of the workspace, which is what keeps
/// it cheap to redraw while a running agent rewrites its diff stat every few seconds. What is here
/// is what the list is told about the row: where it sits, what it is tagged with, what its menu
/// offers, and the archive that menu and the row's own button both go through.
///
/// It was `RepoSection.row(_:)` and moved out of it whole when the pane was flattened into one run
/// of rows. Nothing about a workspace row changed in that move: it is drawn, indented, tagged and
/// right clicked exactly as it was.
struct SidebarWorkspaceRow: View {
    var workspace: Workspace
    /// Which rows have only just been added to the list, so they fade in rather than appear.
    /// Handed down from `SidebarView`, which owns the one tracker the whole pane shares: a
    /// workspace can move between projects, and two trackers would each read that as an arrival
    /// and a departure of their own.
    var arrival: RowArrival<WorkspaceID>
    /// The project this row is under, for the one thing the flat pane cannot say structurally.
    /// See `body`, and `RepoHeaderRow.name` for why this is words rather than an outline level.
    var projectName: String
    /// The project, when the row has to draw its tile because no header above it says which project
    /// this is. Only the status view passes one. See `WorkspaceRow.trailingRepo`.
    var trailingRepo: Repo?
    /// Whether this workspace's subagent rows are open. The set lives in `SidebarView`, because the
    /// rows it controls are built there.
    var isShowingSubagents: Bool = false
    var onToggleSubagents: (() -> Void)?
    var showsDiffStats = false
    @Binding var renaming: WorkspaceID?
    @Binding var archivePresentation: SidebarArchivePresentation

    @Environment(AppModel.self) private var app
    @Environment(\.sidebarRowIndent) private var rowIndent

    private typealias ArchiveSource = SidebarArchivePresentation.Source

    private var isArchiveActive: Bool {
        archivePresentation.workspaceID == workspace.id
            && (archivePresentation.request != nil || archivePresentation.isRequesting)
    }

    var body: some View {
        WorkspaceRow(
            workspace: workspace,
            isRunning: app.isRunning(workspace),
            isAwaitingPermission: app.isAwaitingPermission(workspace),
            isStarting: app.isStarting(workspace),
            trailingRepo: trailingRepo,
            subagentCount: app.subagents(of: workspace.id).count,
            isShowingSubagents: isShowingSubagents,
            onToggleSubagents: onToggleSubagents,
            showsDiffStats: showsDiffStats,
            renaming: $renaming,
            onArchive: confirmRowArchive,
            isArchiveActive: isArchiveActive,
            archiveRequest: archiveBinding(for: .button),
            onConfirmArchive: confirmArchive
        )
        // Innermost, on the drawing alone. Everything below this line is what the list is told
        // about the row, and a workspace that is fading in is still selectable, draggable and
        // right clickable throughout: it is a row that is fully there and briefly not drawn.
        .arrivingRow(arrival.isArriving(workspace.id))
        .padding(.leading, rowIndent)
        // Which project this row is under.
        //
        // A `Section` said it structurally: the row was an `AXOutlineRow` one disclosure level
        // below its project's, and a screen reader read that level out. The flat run the drag
        // needs has no levels, and the outline's own attributes are not ours to set, which was
        // measured rather than assumed: see `RepoHeaderRow.name`. So the fact is carried as custom
        // content instead, which is the API meant for exactly this: one more thing about a row,
        // said after the row's own label, in the order it is given.
        //
        // High importance, because it is not an extra. A pane of thirty workspace rows with no
        // nesting left in it is unreadable without knowing which project each row belongs to, and
        // content that has to be asked for is content most people never hear.
        .accessibilityCustomContent(Text("Project"), Text(projectName), importance: .high)
        .onAppear { archivePresentation.rowAppeared(workspace.id) }
        .onDisappear {
            archivePresentation.rowDisappeared(workspace.id, isArchiving: app.isArchiving(workspace.id))
        }
        // Every item in it is `WorkspaceMenuItems`, which Home's rows draw from as well. It used
        // to be a copy of the same six buttons written out here, with a note on the other copy
        // saying what to extract when the two were merged; adding to both was what forced it.
        .contextMenu {
            WorkspaceMenuItems(workspace: workspace, onArchive: { archive(from: .row) }) {
                renaming = $0
            }
        }
        .archiveConfirmation(archiveBinding(for: .row), arrowEdge: .leading, onConfirm: confirmArchive)
    }

    /// What the row's archive button does instead of archiving.
    ///
    /// This entry point asks EVERY time, including when nothing is at stake and `AppModel.archive`
    /// would have archived silently. That looks like it contradicts the conditional path, and it
    /// does not: the conditional path is right about the context menu and the keyboard, where you
    /// have already said what you mean by opening a menu or pressing a shortcut, and a
    /// confirmation with nothing to warn about is exactly how a confirmation stops being read.
    /// A hover button is a different thing. It appears under the pointer, unbidden, a few points
    /// from the row you meant to click, which makes it the easiest way in the app to archive
    /// something by accident. So the asking is a property of THIS ENTRY POINT rather than of the
    /// archive: everything else still archives silently when there is nothing to lose.
    ///
    /// It used to ask with a compact dialog of its own, and answering yes could then raise the
    /// model's larger one, so a workspace with real work in it produced two dialogs of different
    /// shapes for a single decision. The asking is still a property of THIS ENTRY POINT, but it
    /// is now said as an argument, and the one dialog that appears is the one that knows what is
    /// at stake. See `AppModel.archive(_:deleteBranch:alwaysConfirm:)`.
    private func confirmRowArchive(_ workspace: Workspace) {
        archive(from: .button, alwaysConfirm: true)
    }

    private func archiveBinding(for source: ArchiveSource) -> Binding<ArchiveRequest?> {
        Binding(
            get: {
                guard archivePresentation.workspaceID == workspace.id,
                      archivePresentation.source == source else { return nil }
                return archivePresentation.request
            },
            set: { request in
                guard request == nil, archivePresentation.workspaceID == workspace.id,
                      archivePresentation.source == source else { return }
                archivePresentation.dismissRequest()
            }
        )
    }

    private func archive(from source: ArchiveSource, alwaysConfirm: Bool = false) {
        let generation = beginArchive(from: source)
        Task {
            defer { archivePresentation.finish(generation: generation) }
            await app.archive(workspace, alwaysConfirm: alwaysConfirm) { request in
                archivePresentation.present(request, generation: generation)
            }
        }
    }

    private func confirmArchive(_ request: ArchiveRequest) {
        let generation = beginArchive(from: archivePresentation.source)
        Task {
            defer { archivePresentation.finish(generation: generation) }
            await app.confirmArchive(request) { fresh in
                archivePresentation.present(fresh, generation: generation)
            }
        }
    }

    private func beginArchive(from source: ArchiveSource) -> UUID {
        return archivePresentation.begin(workspaceID: workspace.id, source: source)
    }
}

/// What stands where a project's workspaces would be when there are none to draw.
///
/// A `Label` with nothing in its icon, so the sentence starts on the same column a workspace's
/// name starts on rather than on a column of its own. It is a sentence about the project, not an
/// item in the list, so it follows the same indicator and content columns as a workspace row.
///
/// It is a row in the run like any other now that the pane is flat, which is why it refuses both
/// selection and the drag: a sentence is not something to pick up, and `SidebarReorder` refuses it
/// a second time in case the outline offers it anyway.
struct SidebarEmptyNoticeRow: View {
    /// Only used to say WHY there is nothing here, which is a different sentence when a filter is
    /// hiding rows than when the project has none.
    var isFiltered: Bool
    var body: some View {
        Label {
            // The project's `+` already creates a workspace, so this notice needs no second action.
            // No font of its own, which is what the rows around it do. It was `Typo.caption`,
            // a size smaller than every name above and below it, and in a pane where each project
            // can carry one of these the small type read as a second class of row rather than as
            // a quiet one. The tertiary ink is what makes it quiet.
            Text(isFiltered ? "Nothing matches the filter" : "No workspaces yet")
                .italic()
                .foregroundStyle(Palette.textTertiary)
        } icon: {
            Image(systemName: "arrow.turn.down.right")
                .font(Typo.caption)
                .imageScale(.small)
                .foregroundStyle(Palette.textTertiary)
                .accessibilityHidden(true)
        }
        // The same layout the rows it stands in for use, so the sentence starts on the primary
        // content column rather than on a column of its own.
        .labelStyle(SidebarRowLabelStyle())
        .padding(.leading, SidebarMetrics.rowIndent)
    }
}
