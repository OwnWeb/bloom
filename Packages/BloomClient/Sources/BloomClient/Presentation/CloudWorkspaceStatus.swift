import Foundation

/// What a Cloud workspace's row says about it, read from runbloom.app's list alone.
///
/// The list is all the sidebar has for a workspace nobody has open, and reading it never wakes a
/// machine, so this is decided from the item's state and last summary and nothing else.
public enum CloudWorkspaceStatus: Sendable, Hashable {
    case settingUp(step: String?)
    case setupFailed
    /// An agent is waiting on a person: a permission, a question or a plan.
    case waiting(kind: String)
    case running
    /// A prompt is held by a team limit.
    case blocked
    case stopping
    case error
    /// Nothing running and the machine awake.
    case idle
    /// Nothing running and the machine asleep, which is the normal resting state.
    case asleep
    case archiving

    /// What the machine itself is doing, for a workspace whose connection is open.
    ///
    /// **Two witnesses, and this one wins while it is listening.** runbloom.app's summary is a poll:
    /// it said `running` for a turn that had already finished and nothing told it otherwise, so the
    /// owner watched a sidebar spinner beside a conversation that had answered him and gone quiet.
    /// The machine's own stream knows the turn ended because it carried the event that ended it.
    ///
    /// Only the activity is taken from it. Whether there is a pull request, whether anybody has
    /// read the last turn and whether the branch has changes are the summary's to answer, because
    /// they are true of a workspace nobody has open and the stream says nothing about them.
    public enum Activity: Sendable, Hashable {
        case running
        case waiting(kind: String)
        case settingUp(step: String?)
        case idle
    }

    /// The status as the machine's own stream tells it, with the summary answering everything the
    /// stream does not. Nil activity is a workspace nobody has open, which is the poll's to
    /// describe alone.
    public init(item: CloudWorkspaceItem, activity: Activity?) {
        guard let activity else {
            self.init(item: item)
            return
        }
        switch activity {
        case .running: self = .running
        case .waiting(let kind): self = .waiting(kind: kind)
        case .settingUp(let step): self = .settingUp(step: step)
        case .idle:
            // A live stream proves the machine is awake, even if the last poll still says it is
            // asleep. Archiving and the refusals stay the summary's, because they are
            // runbloom.app's own facts and the machine does not carry them.
            switch item.state {
            case "archiving", "archived": self = .archiving
            case "blocked": self = .blocked
            case "setup_failed": self = .setupFailed
            case "error": self = .error
            default: self = .idle
            }
        }
    }

    public init(item: CloudWorkspaceItem) {
        switch item.state {
        case "setting_up": self = .settingUp(step: item.summary?.setup?.step)
        case "setup_failed": self = .setupFailed
        case "waiting_for_input": self = .waiting(kind: item.summary?.waiting?.kind ?? "question")
        case "running": self = .running
        case "blocked": self = .blocked
        case "stopping": self = .stopping
        case "error": self = .error
        case "archiving", "archived": self = .archiving
        default: self = item.isAwake ? .idle : .asleep
        }
    }

    /// A short phrase for the row's subtitle and its accessibility label.
    public var phrase: String {
        switch self {
        case .settingUp(let step):
            if let name = CloudSetupStep.short(step) { "Setting up: \(name)" } else { "Setting up" }
        case .setupFailed: "Setup failed"
        case .waiting(let kind):
            switch kind {
            case "permission": "Waiting for permission"
            case "plan": "Plan ready for review"
            default: "Waiting for an answer"
            }
        case .running: "Working"
        case .blocked: "Held by a team limit"
        case .stopping: "Stopping"
        case .error: "Something went wrong"
        case .idle: "Ready"
        case .asleep: "Asleep"
        case .archiving: "Archiving"
        }
    }

    public var needsAttention: Bool {
        switch self {
        case .waiting, .setupFailed, .blocked, .error: true
        default: false
        }
    }

    public var isWorking: Bool {
        switch self {
        case .running, .settingUp, .stopping: true
        default: false
        }
    }

}

/// The sidebar's own mark for a Cloud workspace's row, as the name of a `WorkspaceStatus`.
///
/// **A name rather than the type, because the type is in `BloomCore` and this package cannot see
/// it.** What is worth having here rather than in the app is the precedence: which of the workspace
/// facts wins when several are true at once. That is the rule a local row already follows, and it
/// has to be the same rule or one column says two things. The app turns the name into the value
/// with `WorkspaceStatus(rawValue:)`, which is what the name is taken from.
public enum CloudSidebarMark {
    public static func name(for item: CloudWorkspaceItem, activity: CloudWorkspaceStatus.Activity? = nil) -> String {
        switch CloudWorkspaceStatus(item: item, activity: activity) {
        case .settingUp, .stopping, .archiving: "settingUp"
        // Held by a team limit is nothing running and nothing about to, until somebody raises it:
        // the shape of a setup that failed rather than of an idle row.
        case .setupFailed, .error, .blocked: "setupFailed"
        case .waiting: "awaitingPermission"
        case .running: "running"
        case .idle, .asleep: branchName(for: item)
        }
    }

    /// What is true of the branch with the agent left out of it, in the order a local workspace
    /// weighs it: what GitHub says first, then whether anybody has read the last turn, then
    /// whether there is anything on the branch at all.
    static func branchName(for item: CloudWorkspaceItem) -> String {
        if let pullRequest = item.summary?.pullRequest {
            switch (pullRequest.state ?? "open").lowercased() {
            case "merged": return "merged"
            case "closed": return "closed"
            default: return "pullRequestOpen"
            }
        }
        if item.unread { return "unread" }
        return (item.summary?.diff?.files ?? 0) > 0 ? "changed" : "clean"
    }
}
