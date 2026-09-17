import BloomClient
import BloomCore
import Foundation

/// A Cloud workspace's row as the sidebar's own vocabulary, so one column says one thing.
///
/// **The marks are the workspace's, not the cloud's.** The row used to draw clouds: a filled one
/// for working, an outline for asleep, a struck-through one for a failure. That is a second
/// vocabulary for the same questions the rest of the column already answers, and the reader has to
/// learn both. Which section a row is in already says it runs in the cloud; what the mark is for is
/// whether an agent is working, whether it is waiting on a person, whether anybody has read what it
/// said, and what GitHub thinks of the branch.
///
/// Read from runbloom.app's list alone, which is what the sidebar has for a workspace nobody has
/// open, so nothing here wakes a machine.
extension WorkspaceStatus {
    /// The precedence is `CloudSidebarMark`'s, beside the records and under test; this is the one
    /// line that turns its answer back into the type. A name this version does not know reads as
    /// a workspace with nothing to say rather than as no row at all.
    init(cloudItem item: CloudWorkspaceItem) {
        self = WorkspaceStatus(rawValue: CloudSidebarMark.name(for: item)) ?? .clean
    }
}
