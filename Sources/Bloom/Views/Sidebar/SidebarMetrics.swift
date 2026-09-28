import BloomCore
import SwiftUI

/// The measurements that make the source list one column rather than three.
///
/// Taken off a reference render of this window with the sidebar at its 260 point default. They
/// are here rather than in `Metrics` because they describe one pane's internal rhythm and were
/// arrived at by measuring a picture, not by reasoning from the scale. Candidates for promotion
/// once the rest of the window has been measured the same way.
///
/// There is deliberately no row height here. A `List` with `.listStyle(.sidebar)` sizes its rows
/// itself and ignores every lever offered for changing that: `listRowInsets`, an explicit
/// `frame(height:)` on the row, `defaultMinListRowHeight` and `controlSize` were each captured
/// and each left the pitch at exactly 32 points. The reference draws 28. Reaching it would mean
/// leaving `.listStyle(.sidebar)`, and with it AppKit selection, keyboard navigation and the
/// standard insets. Project rows rely on those insets without adding their own vertical padding.
///
/// Project headers are plain rows in the flat list and use the full 32 points. The old `Section`
/// headers had only 19 points for content below 13 points of spacing.
enum SidebarMetrics {
    private static let columns = SidebarColumnLayout(
        disclosureWidth: caretGutter,
        spacing: Metrics.spacing
    )

    /// The gutter the project's disclosure chevron sits in, at the leading edge of a header.
    ///
    /// Wide enough for the chevron and nothing else. It is what pushes the project's tile clear of
    /// the pane's own edge, and the rows underneath start on the far side of it, so the two
    /// numbers are one number.
    static let caretGutter: CGFloat = 11

    /// Workspace rows use the list's own leading inset. Their status occupies the project's
    /// disclosure column, so adding another project-level inset would spend the same hierarchy
    /// width twice.
    static let rowIndent = columns.workspaceIndent

    /// The box a row's status mark is centred in, matching the disclosure control exactly.
    ///
    /// How large the marks inside it are drawn is NOT here, and deliberately. `Metrics.glyph`,
    /// `Metrics.glyphInk` and `Metrics.dot` are one family, and Home, the tab strip and the
    /// transcript read them as well as this pane does: a size named after one pane and used from
    /// another is how the two drift, which is the argument `Metrics.headerButton` already carries.
    /// This is the column the marks are centred in; those three are the marks.
    static let markColumn = columns.indicatorWidth

    /// The leading edge shared by the project icon and every workspace's primary text.
    static let contentColumn = columns.primaryContentLeading

    /// The project's own name remains one icon and one gap beyond its icon.
    static let projectNameColumn = contentColumn + Metrics.repoIcon + Metrics.spacing

    /// How far a subagent's row is pushed right of the workspace row it belongs to.
    ///
    /// The chevron's gutter, so a subagent's mark and its name each sit one step right of the
    /// workspace's. It is a real step because it has to be: a workspace row begins at the project
    /// icon rather than stepping in from it, so the only thing left saying a subagent is inside
    /// its workspace is this indent. It is also the last step this pane gets, because a
    /// fourth would leave a name six characters wide at the 260 point default, which is why
    /// `SubagentRow.rows` draws a subagent's own children at this indent rather than one further
    /// in.
    static let subagentIndent = columns.childIndent

    /// Where a crew member's row begins, one deliberate step beneath its workspace.
    ///
    /// Crew members and live subagents share the same step, so neither invents a third column.
    static let crewIndent: CGFloat = crewIndent(rowIndent: rowIndent)

    /// `crewIndent` for a pane whose workspace rows start at `rowIndent`, which is zero in the
    /// status view. See `EnvironmentValues.sidebarRowIndent`.
    static func crewIndent(rowIndent: CGFloat) -> CGFloat {
        rowIndent + subagentIndent
    }

    /// The click target of a control that lives on a workspace row, such as the archive button
    /// that is revealed under the pointer.
    ///
    /// Deliberately small. A destructive control at the trailing edge of a row you are about to
    /// click has to be unambiguous, and every point it grows is a point of the row it steals. It
    /// is square and a little larger than the mark it draws, so it is comfortable to hit without
    /// reaching towards the name.
    static let rowButton: CGFloat = 20

    /// How far a hidden project's header is played down when the owner has asked to see the
    /// hidden ones.
    ///
    /// One opacity over the whole header, so the tile and the name step back together. Conductor
    /// draws its hidden repositories at the same size and in the same place as the rest, in less
    /// contrast, and that restraint is the whole point: a hidden project is still a project.
    ///
    /// A little under half, which is the step this pane already uses between something that is
    /// there and something that is barely there. Lower and the tile's own colour goes muddy
    /// against the sidebar material in dark mode; higher and the two ranks are not tellable apart
    /// at a glance, which is the one thing this has to do.
    static let hiddenDim: Double = 0.45

    /// How large the chevron itself is drawn. Roughly a five point mark: the smallest thing in
    /// the pane, because it is furniture rather than content.
    static let caretSize: CGFloat = 9
}

extension EnvironmentValues {
    /// How far the pane's rows start right of the leading edge the list hands them.
    ///
    /// Zero in both project and status groupings. The fixed indicator column now carries the
    /// hierarchy alignment without pushing the whole row right.
    @Entry var sidebarRowIndent: CGFloat = SidebarMetrics.rowIndent
}
