import Foundation

/// The one workspace this server holds, as a client draws its header.
public struct WorkspaceRecord: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var branch: String
    public var baseBranch: String
    public var setup: SetupRecord
    public var pullRequest: PullRequestRecord?
    /// Present only when there is something wrong to say about the machine's own reporting. See
    /// `ReportingRecord`.
    public var reporting: ReportingRecord?

    public init(id: String, name: String, branch: String, baseBranch: String, setup: SetupRecord,
                pullRequest: PullRequestRecord? = nil, reporting: ReportingRecord? = nil) {
        self.id = id
        self.name = name
        self.branch = branch
        self.baseBranch = baseBranch
        self.setup = setup
        self.pullRequest = pullRequest
        self.reporting = reporting
    }

    enum CodingKeys: String, CodingKey {
        case id, name, branch, setup, reporting
        case baseBranch = "base_branch"
        case pullRequest = "pull_request"
    }
}

/// The machine saying it cannot reach runbloom.app, which is the one failure nobody could see.
///
/// Everything else that goes wrong between a machine and runbloom.app fails in front of somebody:
/// a prompt that cannot start pauses its chat with a sentence, a push that has no credential says
/// so. Summaries and usage reports fail quietly, because nobody is waiting on them, and the only
/// symptom is that the workspace list somewhere else goes stale. So the machine says it here, and
/// a client shows it: this workspace is running, and what it is doing is not being recorded.
///
/// Absent while everything is in touch and nothing has been shed, which is almost always.
public struct ReportingRecord: Codable, Sendable, Hashable {
    /// The moment contact was lost, which is the last report that got through, or this server's
    /// start when none ever has. Nil means in touch. What a client says is "not reported since
    /// <this>".
    public var unreachableSince: Date?
    /// Reports thrown away because the queue reached its cap. What is lost is detail: the counters
    /// are cumulative, so what a workspace cost is still right afterwards, and what is gone is the
    /// account of which turns made up the oldest of it. Cumulative since this server started.
    public var shed: Int

    public init(unreachableSince: Date? = nil, shed: Int = 0) {
        self.unreachableSince = unreachableSince
        self.shed = shed
    }

    enum CodingKeys: String, CodingKey {
        case shed
        case unreachableSince = "unreachable_since"
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
