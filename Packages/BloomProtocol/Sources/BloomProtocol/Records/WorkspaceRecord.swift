import Foundation

/// The one workspace this server holds, as a client draws its header.
public struct WorkspaceRecord: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var branch: String
    public var baseBranch: String
    public var setup: SetupRecord
    public var pullRequest: PullRequestRecord?

    public init(id: String, name: String, branch: String, baseBranch: String, setup: SetupRecord, pullRequest: PullRequestRecord? = nil) {
        self.id = id
        self.name = name
        self.branch = branch
        self.baseBranch = baseBranch
        self.setup = setup
        self.pullRequest = pullRequest
    }

    enum CodingKeys: String, CodingKey {
        case id, name, branch, setup
        case baseBranch = "base_branch"
        case pullRequest = "pull_request"
    }
}

public struct PullRequestRecord: Codable, Sendable, Hashable {
    public var number: Int
    public var url: String
    public var title: String
    public var state: String

    public init(number: Int, url: String, title: String, state: String) {
        self.number = number
        self.url = url
        self.title = title
        self.state = state
    }
}

/// Setup as a whole: which step is running, and how the last run ended.
///
/// `state` is `pending`, `running`, `succeeded`, `failed` or `skipped`. `step` names the script
/// running now (`clone`, `prepare`, `setup`, `resume`, `services`) and is nil when none is.
public struct SetupRecord: Codable, Sendable, Hashable {
    public var state: String
    public var step: String?
    public var startedAt: Date?
    public var finishedAt: Date?
    /// The last lines of a failed run, so a client can say what went wrong without asking for the
    /// whole setup output. Nil while setup is going and when it succeeded.
    public var note: String?

    public init(state: String, step: String? = nil, startedAt: Date? = nil, finishedAt: Date? = nil, note: String? = nil) {
        self.state = state
        self.step = step
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case state, step, note
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }
}

/// The setup output so far, for a client that opened the workspace in the middle of it.
public struct SetupOutputRecord: Codable, Sendable, Hashable {
    public var setup: SetupRecord
    public var log: String

    public init(setup: SetupRecord, log: String) {
        self.setup = setup
        self.log = log
    }
}
