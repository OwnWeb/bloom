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
    init(cloudItem item: CloudWorkspaceItem) {
        let state = CloudWorkspaceStatus(item: item)
        switch state {
        case .settingUp, .stopping, .archiving:
            self = .settingUp
        case .setupFailed, .error:
            self = .setupFailed
        case .waiting:
            self = .awaitingPermission
        case .running:
            self = .running
        case .blocked:
            // Held by a team limit: nothing is running and nothing will until somebody raises it,
            // which is the same shape of fact as a setup that failed rather than as an idle row.
            self = .setupFailed
        case .idle, .asleep:
            self = WorkspaceStatus.ofBranch(cloudItem: item, isUnread: item.unread)
        }
    }

    /// What is true of the branch and whatever pull request runbloom.app last saw, with the agent
    /// left out of it. The same precedence a local workspace's branch takes, asked of the summary.
    static func ofBranch(cloudItem item: CloudWorkspaceItem, isUnread: Bool) -> WorkspaceStatus {
        if let pullRequest = item.summary?.pullRequest {
            switch (pullRequest.state ?? "open").lowercased() {
            case "merged": return .merged
            case "closed": return .closed
            default: return .pullRequestOpen
            }
        }
        if isUnread { return .unread }
        let diff = item.summary?.diff
        return (diff?.files ?? 0) > 0 ? .changed : .clean
    }
}
