import Foundation

/// The one workspace this server holds, as a client draws its header.
///
/// **No pull request.** It had a `pull_request` field that nothing on the machine ever filled, and
/// a Mac fallback reading it that therefore never had a value. A pull request is runbloom.app's
/// knowledge, read through its GitHub App, and a client asks there; a second, possibly stale copy
/// from the machine's own `gh` is what was decided against on 18 September 2026.
public struct WorkspaceRecord: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var branch: String
    public var baseBranch: String
    public var setup: SetupRecord
    /// Present only when there is something wrong to say about the machine's own reporting. See
    /// `ReportingRecord`.
    public var reporting: ReportingRecord?
    /// The `[[services]]` this project declares, as the machine is running them. Empty for a
    /// workspace that declares none, and on a Mac.
    public var services: [ServiceRecord]

    public init(id: String, name: String, branch: String, baseBranch: String, setup: SetupRecord,
                reporting: ReportingRecord? = nil, services: [ServiceRecord] = []) {
        self.id = id
        self.name = name
        self.branch = branch
        self.baseBranch = baseBranch
        self.setup = setup
        self.reporting = reporting
        self.services = services
    }

    enum CodingKeys: String, CodingKey {
        case id, name, branch, setup, reporting, services
        case baseBranch = "base_branch"
    }

    /// `services` was added on 18 September 2026 and every machine in the field predates it, so it
    /// is read as absent-means-none. See `WorkspaceSnapshotRecord.init(from:)` for the rule and
    /// what it costs to miss: a required key here is not a workspace without services, it is a
    /// workspace that will not open.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        branch = try container.decode(String.self, forKey: .branch)
        baseBranch = try container.decode(String.self, forKey: .baseBranch)
        setup = try container.decode(SetupRecord.self, forKey: .setup)
        reporting = try container.decodeIfPresent(ReportingRecord.self, forKey: .reporting)
        services = try container.decodeIfPresent([ServiceRecord].self, forKey: .services) ?? []
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

/// One of a project's `[[services]]`, as the machine is running it.
///
/// **A service that never started is otherwise invisible.** The supervisor launches a service only
/// once every name in its `depends_on` is ready, so one whose dependency never comes up waits for
/// ever: never launched, never failed, never restarted, and its whole existence a sentence held in
/// the machine's memory. Until this record that sentence reached a person in exactly one place, the
/// preview's own "the app is not answering" page, which cannot be reached at all when a project
/// runs its own proxy on the previewed port. On 18 September 2026 a workspace had four services up
/// and a fifth crash-looping against Bloom Runner's port every second, and the only account of it
/// was a log nobody was looking at.
///
/// **The difference this makes is between "the preview is blank" and "your app service cannot bind
/// 8081", which is the difference between a mystery and an afternoon's work avoided.**
public struct ServiceRecord: Codable, Sendable, Hashable {
    public var name: String
    /// `waiting`, `starting`, `running`, `not_ready`, `crashed` or `stopped`.
    public var state: String
    /// The one the preview routes to, which is the service the project marked `http = true`.
    ///
    /// **A fact rather than an instruction about what to draw.** Two clients wanted opposite things
    /// from it and both are right: one asks "can I open the preview yet", which is this service and
    /// no other, and one asks "why is it not up", which is usually a different service entirely,
    /// because the thing holding the app back is the database it waits for. So the machine says
    /// which one it is and neither client has to infer it from a name.
    public var isHTTP: Bool
    /// How many times it has exited since it was started.
    public var restarts: Int
    /// What it is waiting for, or how it ended, in a sentence meant for a person.
    public var message: String?

    public init(name: String, state: String, restarts: Int = 0, message: String? = nil, isHTTP: Bool = false) {
        self.name = name
        self.state = state
        self.isHTTP = isHTTP
        self.restarts = restarts
        self.message = message
    }

    enum CodingKeys: String, CodingKey {
        case name, state, restarts, message
        case isHTTP = "http"
    }

    /// Absent means no, for a machine built before the field. See `WorkspaceSnapshotRecord`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        state = try container.decode(String.self, forKey: .state)
        restarts = try container.decode(Int.self, forKey: .restarts)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        isHTTP = try container.decodeIfPresent(Bool.self, forKey: .isHTTP) ?? false
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
