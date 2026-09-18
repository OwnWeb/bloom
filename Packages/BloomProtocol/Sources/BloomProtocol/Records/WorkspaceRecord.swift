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
    /// Whether this workspace runs setup scripts at all. False is a workspace somebody created
    /// asking for none, where `skipped` is the ordinary outcome rather than something to fix, and
    /// a client should offer to run setup rather than report that it failed to.
    ///
    /// **`enabled` on the wire, not `run_setup`**, which is what the machine's own configuration
    /// file calls the same fact. There is already a `run_setup` *method* in this protocol, meaning
    /// run setup again now, and a field beside it with that name would read as a command rather
    /// than as a property of the workspace. The machine's own configuration file calls the same
    /// fact `run_setup`, and that is right there: a file is read once and obeyed, so the key is a
    /// property in the place it is written. `MachineConfiguration.runSetup` carries this from the
    /// other end. **Two audiences, two words, on purpose**, and both ends say so, because an
    /// inconsistency with no defence beside it is one somebody helpfully removes later.
    public var isEnabled: Bool

    public init(state: String, step: String? = nil, startedAt: Date? = nil, finishedAt: Date? = nil,
                note: String? = nil, isEnabled: Bool = true) {
        self.state = state
        self.step = step
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.note = note
        self.isEnabled = isEnabled
    }

    enum CodingKeys: String, CodingKey {
        case state, step, note
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case isEnabled = "enabled"
    }

    /// Absent means yes, for the reason `MachineConfiguration.runSetup` gives: a client reading an
    /// older machine's reply should see the behaviour that machine actually has.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(String.self, forKey: .state)
        step = try container.decodeIfPresent(String.self, forKey: .step)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
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
