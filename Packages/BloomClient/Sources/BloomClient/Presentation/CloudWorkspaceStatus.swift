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
            if let step, let name = Self.stepNames[step] { "Setting up: \(name)" } else { "Setting up" }
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

    private static let stepNames = [
        "clone": "cloning", "prepare": "preparing", "setup": "running setup",
        "resume": "resuming", "services": "starting services",
    ]
}

/// The sidebar's own mark for a Cloud workspace's row, as the name of a `WorkspaceStatus`.
///
/// **A name rather than the type, because the type is in `BloomCore` and this package cannot see
/// it.** What is worth having here rather than in the app is the precedence: which of the workspace
/// facts wins when several are true at once. That is the rule a local row already follows, and it
/// has to be the same rule or one column says two things. The app turns the name into the value
/// with `WorkspaceStatus(rawValue:)`, which is what the name is taken from.
public enum CloudSidebarMark {
    public static func name(for item: CloudWorkspaceItem) -> String {
        switch CloudWorkspaceStatus(item: item) {
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
