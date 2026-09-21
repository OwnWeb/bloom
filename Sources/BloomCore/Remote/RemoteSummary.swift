import Foundation

/// What runbloom.app lists a Cloud workspace with, so a list never has to wake a machine.
///
/// `POST /api/machine/workspaces/{id}/summary`, replace-latest: a monotonic `revision` means a
/// late post never overwrites a newer one. See docs/REMOTE-WORKSPACES.md, "Summaries", and
/// runbloom.app's own design document, which reads exactly these fields.
public struct RemoteSummary: Codable, Sendable, Hashable {
    public struct Setup: Codable, Sendable, Hashable {
        /// What the machine found under the step it is running, so that runbloom.app can act on a
        /// fact rather than on the age of a timestamp.
        ///
        /// **The machine is the only party that can see the child**, which is the whole reason this
        /// exists. A step that has printed nothing for five minutes looks identical from outside to
        /// one that has died, and acting on that inference restarted a machine while `composer` and
        /// `bun` were still installing, throwing away their caches so the retry was slower than the
        /// run it killed. Only `nothing_alive` is a reason to act on. **Absent is no signal at all
        /// and must not be read as a stall**: an older machine says nothing here, and so does a
        /// machine between steps.
        public struct Liveness: Codable, Sendable, Hashable {
            /// `working`, `waiting` or `nothing_alive`. See `StepLiveness.Verdict`.
            public var verdict: String
            /// Processes alive under the step's own child, including it.
            public var running: Int
            /// Processes that exited and were not collected.
            public var defunct: Int
            public var at: Date

            public init(verdict: String, running: Int, defunct: Int, at: Date) {
                self.verdict = verdict
                self.running = running
                self.defunct = defunct
                self.at = at
            }
        }

        public var state: String
        public var step: String?
        public var startedAt: Date?
        public var finishedAt: Date?
        public var liveness: Liveness?

        enum CodingKeys: String, CodingKey {
            case state, step, liveness
            case startedAt = "started_at"
            case finishedAt = "finished_at"
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(state, forKey: .state)
            try container.encodeOrNull(step, forKey: .step)
            try container.encodeOrNull(startedAt, forKey: .startedAt)
            try container.encodeOrNull(finishedAt, forKey: .finishedAt)
            try container.encodeOrNull(liveness, forKey: .liveness)
        }
    }

    public struct LastMessage: Codable, Sendable, Hashable {
        public var chatID: String
        /// `agent` or `user`.
        public var authorKind: String
        public var authorUserID: String?
        public var excerpt: String
        public var at: Date

        enum CodingKeys: String, CodingKey {
            case excerpt, at
            case chatID = "chat_id"
            case authorKind = "author_kind"
            case authorUserID = "author_user_id"
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(chatID, forKey: .chatID)
            try container.encode(authorKind, forKey: .authorKind)
            try container.encodeOrNull(authorUserID, forKey: .authorUserID)
            try container.encode(excerpt, forKey: .excerpt)
            try container.encode(at, forKey: .at)
        }
    }

    public struct Waiting: Codable, Sendable, Hashable {
        /// `permission`, `question` or `plan`.
        public var kind: String
        public var chatID: String
        public var since: Date

        enum CodingKeys: String, CodingKey {
            case kind, since
            case chatID = "chat_id"
        }
    }

    public struct Diff: Codable, Sendable, Hashable {
        public var files: Int
        public var additions: Int
        public var deletions: Int

        public init(files: Int, additions: Int, deletions: Int) {
            self.files = files
            self.additions = additions
            self.deletions = deletions
        }
    }

    public struct PullRequest: Codable, Sendable, Hashable {
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

    public struct Chat: Codable, Sendable, Hashable {
        public var id: String
        public var title: String
        public var agent: String
        public var state: String
    }

    public var revision: Int64
    public var observedAt: Date
    public var bloomRunnerVersion: String
    /// Security capabilities proved by this running process, not features compiled into it.
    public var bloomRunnerCapabilities: [String]
    public var title: String
    public var branch: String
    public var baseBranch: String
    public var state: String
    public var awake: Bool
    public var presenceLeaseUntil: Date?
    public var setup: Setup
    public var lastMessage: LastMessage?
    public var waiting: Waiting?
    public var runningSince: Date?
    public var diff: Diff
    /// What exists only on this machine, measured apart from `diff` and left out of the payload
    /// entirely when it could not be measured. A zero here would read as "nothing at stake" to the
    /// archive confirmation, which is the one place that must never guess. See `RemoteWorkAtStake`.
    public var uncommitted: Int?
    public var untracked: Int?
    public var unpushedCommits: Int?
    public var pullRequest: PullRequest?
    public var chats: [Chat]
    public var presentUserIDs: [String]

    enum CodingKeys: String, CodingKey {
        case revision, title, branch, state, awake, setup, waiting, diff, chats
        case uncommitted, untracked
        case unpushedCommits = "unpushed_commits"
        case observedAt = "observed_at"
        case bloomRunnerVersion = "bloom_runner_version"
        case bloomRunnerCapabilities = "bloom_runner_capabilities"
        case baseBranch = "base_branch"
        case presenceLeaseUntil = "presence_lease_until"
        case lastMessage = "last_message"
        case runningSince = "running_since"
        case pullRequest = "pull_request"
        case presentUserIDs = "present_user_ids"
    }

    /// Every optional field goes out as `null` rather than being left out, because runbloom.app
    /// replaces its stored summary with each post and a missing key would read as "unchanged" to a
    /// reader in another language, where `null` unambiguously says "none".
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(revision, forKey: .revision)
        try container.encode(observedAt, forKey: .observedAt)
        try container.encode(bloomRunnerVersion, forKey: .bloomRunnerVersion)
        try container.encode(bloomRunnerCapabilities, forKey: .bloomRunnerCapabilities)
        try container.encode(title, forKey: .title)
        try container.encode(branch, forKey: .branch)
        try container.encode(baseBranch, forKey: .baseBranch)
        try container.encode(state, forKey: .state)
        try container.encode(awake, forKey: .awake)
        try container.encodeOrNull(presenceLeaseUntil, forKey: .presenceLeaseUntil)
        try container.encode(setup, forKey: .setup)
        try container.encodeOrNull(lastMessage, forKey: .lastMessage)
        try container.encodeOrNull(waiting, forKey: .waiting)
        try container.encodeOrNull(runningSince, forKey: .runningSince)
        try container.encode(diff, forKey: .diff)
        // `encodeIfPresent`, not `encodeOrNull` as everything else here: for these three, a missing
        // key is the message. Null or zero would both be read as an answer.
        try container.encodeIfPresent(uncommitted, forKey: .uncommitted)
        try container.encodeIfPresent(untracked, forKey: .untracked)
        try container.encodeIfPresent(unpushedCommits, forKey: .unpushedCommits)
        try container.encodeOrNull(pullRequest, forKey: .pullRequest)
        try container.encode(chats, forKey: .chats)
        try container.encode(presentUserIDs, forKey: .presentUserIDs)
    }

    /// The same summary with the fields that change on every post blanked, for deciding whether
    /// anything a reader cares about moved since the last one.
    public var content: RemoteSummary {
        var copy = self
        copy.revision = 0
        copy.observedAt = Date(timeIntervalSince1970: 0)
        return copy
    }
}

extension RemoteSummary {
    /// One chat as the summary sees it.
    public struct ChatActivity: Sendable, Hashable {
        public var busy: Bool
        public var waitingSince: Date?
        public var waitingKind: String?
        public var blocked: Bool
        public var stopping: Bool

        public init(busy: Bool = false, waitingSince: Date? = nil, waitingKind: String? = nil, blocked: Bool = false, stopping: Bool = false) {
            self.busy = busy
            self.waitingSince = waitingSince
            self.waitingKind = waitingKind
            self.blocked = blocked
            self.stopping = stopping
        }

        public var state: String {
            if waitingSince != nil { return "waiting_for_input" }
            if stopping { return "stopping" }
            if busy { return "running" }
            if blocked { return "blocked" }
            return "idle"
        }
    }

    /// The workspace's one word, from its setup and its chats.
    ///
    /// Setup first, because nothing runs until it ends. Then whatever needs a person, because that
    /// is what a list is for; then work in progress; and a failed setup only when nothing has
    /// happened since, because prompts go after setup however it ended and a workspace somebody is
    /// working in is not a failed one.
    public static func state(setup: SetupState, chats: [ChatActivity]) -> String {
        if setup == .pending || setup == .running { return "setting_up" }
        if chats.contains(where: { $0.waitingSince != nil }) { return "waiting_for_input" }
        if chats.contains(where: \.stopping) { return "stopping" }
        if chats.contains(where: \.busy) { return "running" }
        if chats.contains(where: \.blocked) { return "blocked" }
        if setup == .failed { return "setup_failed" }
        return "idle"
    }
}

/// When a changed summary may go out.
///
/// At once for what a person is waiting to see (a turn starting or ending, a question, a setup
/// step, a name, a branch, a pull request, an error, going to sleep), but never more than one post
/// every two seconds; the diff and presence, which move constantly while an agent works, at most
/// every thirty. Pure, so the rates are tested rather than trusted.
public struct RemoteSummarySchedule: Sendable, Hashable {
    public static let minimumInterval: TimeInterval = 2
    public static let slowInterval: TimeInterval = 30

    public enum Change: Sendable, Hashable {
        /// Worth telling a person about now.
        case prompt
        /// The diff or presence moved.
        case slow
    }

    public private(set) var lastPostAt: Date?
    public private(set) var lastSlowPostAt: Date?

    public init() {}

    /// When a post carrying this change should go.
    public func due(for change: Change, now: Date) -> Date {
        var due = now
        if let last = lastPostAt { due = max(due, last.addingTimeInterval(Self.minimumInterval)) }
        if change == .slow, let slow = lastSlowPostAt { due = max(due, slow.addingTimeInterval(Self.slowInterval)) }
        return due
    }

    public mutating func posted(at date: Date, includedSlowChanges: Bool) {
        lastPostAt = date
        if includedSlowChanges { lastSlowPostAt = date }
    }
}

extension KeyedEncodingContainer {
    /// `null` for nil rather than leaving the key out, with the value itself encoded as its own
    /// type so a date still goes through the encoder's date strategy.
    mutating func encodeOrNull<Value: Encodable>(_ value: Value?, forKey key: Key) throws {
        if let value { try encode(value, forKey: key) } else { try encodeNil(forKey: key) }
    }
}
