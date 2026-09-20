import Foundation

/// What runbloom.app knows about a Cloud workspace's branch on GitHub.
///
/// **Read from runbloom.app rather than from the machine, and cached rather than live.** A
/// scheduled refresh writes this every minute, so it is up to a minute old and says so: `fetchedAt`
/// is for the sentence a reader sees and `stale` is for the decision a control takes. Nothing here
/// should be built on a change showing up the instant somebody pushes.
///
/// The branch with no pull request is the same endpoint answering three fields, which is why
/// `hasPullRequest` is the first thing anything here asks.
public struct CloudPullRequestState: Decodable, Sendable, Hashable {
    public var hasPullRequest: Bool
    public var headBranch: String
    public var baseBranch: String
    /// When runbloom.app last asked GitHub. Shown rather than hidden, because a strip that implies
    /// it is live is a strip that lies once a minute.
    public var fetchedAt: Date?
    public var stale: Bool

    public var number: Int?
    public var url: String?
    public var title: String?
    /// `open`, `closed` or `merged`, in runbloom.app's own lower case.
    public var state: String?
    public var isDraft: Bool?
    /// Three-valued on purpose: GitHub answers null while it is still working the merge out, and
    /// "not known yet" is not "no". Anything that reads this as a `Bool` is wrong.
    public var mergeable: Bool?
    public var mergeableState: String?
    /// Derived by runbloom.app from `mergeable_state`, so the Mac does not have to know GitHub's
    /// vocabulary for a branch that no longer applies.
    public var conflicts: Bool?
    public var reviewDecision: String?
    /// Why GitHub would refuse a merge now, in sentences meant for a person.
    public var mergeBlockers: [String]?
    public var headSHA: String?
    public var mergeMethods: [String]?
    public var checks: CloudChecksRollup?
    public var additions: Int?
    public var deletions: Int?
    public var changedFiles: Int?
    public var commits: Int?
    public var updatedAt: Date?
    /// Whether the signed-in person may merge it, which is what greys the Merge control. Present
    /// only where there is a pull request.
    public var canMerge: Bool?

    enum CodingKeys: String, CodingKey {
        case number, url, title, state, mergeable, conflicts, commits, additions, deletions, checks, stale
        case hasPullRequest = "has_pull_request"
        case headBranch = "head_branch"
        case baseBranch = "base_branch"
        case fetchedAt = "fetched_at"
        case isDraft = "is_draft"
        case mergeableState = "mergeable_state"
        case reviewDecision = "review_decision"
        case mergeBlockers = "merge_blockers"
        case headSHA = "head_sha"
        case mergeMethods = "merge_methods"
        case changedFiles = "changed_files"
        case updatedAt = "updated_at"
        case canMerge = "can_merge"
    }

    /// Written out rather than synthesised, because a timestamp arrives as text and runbloom.app
    /// writes microseconds where `ISO8601DateFormatter` expects at most milliseconds. See
    /// `RunbloomDate`, which every date in this package goes through for that reason.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hasPullRequest = try c.decodeIfPresent(Bool.self, forKey: .hasPullRequest) ?? false
        headBranch = try c.decodeIfPresent(String.self, forKey: .headBranch) ?? ""
        baseBranch = try c.decodeIfPresent(String.self, forKey: .baseBranch) ?? ""
        fetchedAt = try c.decodeIfPresent(RunbloomDate.self, forKey: .fetchedAt)?.date
        stale = try c.decodeIfPresent(Bool.self, forKey: .stale) ?? false
        number = try c.decodeIfPresent(Int.self, forKey: .number)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        state = try c.decodeIfPresent(String.self, forKey: .state)
        isDraft = try c.decodeIfPresent(Bool.self, forKey: .isDraft)
        mergeable = try c.decodeIfPresent(Bool.self, forKey: .mergeable)
        mergeableState = try c.decodeIfPresent(String.self, forKey: .mergeableState)
        conflicts = try c.decodeIfPresent(Bool.self, forKey: .conflicts)
        reviewDecision = try c.decodeIfPresent(String.self, forKey: .reviewDecision)
        mergeBlockers = try c.decodeIfPresent([String].self, forKey: .mergeBlockers)
        headSHA = try c.decodeIfPresent(String.self, forKey: .headSHA)
        mergeMethods = try c.decodeIfPresent([String].self, forKey: .mergeMethods)
        checks = try c.decodeIfPresent(CloudChecksRollup.self, forKey: .checks)
        additions = try c.decodeIfPresent(Int.self, forKey: .additions)
        deletions = try c.decodeIfPresent(Int.self, forKey: .deletions)
        changedFiles = try c.decodeIfPresent(Int.self, forKey: .changedFiles)
        commits = try c.decodeIfPresent(Int.self, forKey: .commits)
        updatedAt = try c.decodeIfPresent(RunbloomDate.self, forKey: .updatedAt)?.date
        canMerge = try c.decodeIfPresent(Bool.self, forKey: .canMerge)
    }

    /// For the tests and for a caller building one by hand.
    public init(hasPullRequest: Bool, headBranch: String = "", baseBranch: String = "", fetchedAt: Date? = nil,
                stale: Bool = false, number: Int? = nil, url: String? = nil, title: String? = nil,
                state: String? = nil, isDraft: Bool? = nil, mergeable: Bool? = nil, mergeableState: String? = nil,
                conflicts: Bool? = nil, reviewDecision: String? = nil, mergeBlockers: [String]? = nil,
                headSHA: String? = nil, mergeMethods: [String]? = nil, checks: CloudChecksRollup? = nil,
                canMerge: Bool? = nil) {
        self.hasPullRequest = hasPullRequest
        self.headBranch = headBranch
        self.baseBranch = baseBranch
        self.fetchedAt = fetchedAt
        self.stale = stale
        self.number = number
        self.url = url
        self.title = title
        self.state = state
        self.isDraft = isDraft
        self.mergeable = mergeable
        self.mergeableState = mergeableState
        self.conflicts = conflicts
        self.reviewDecision = reviewDecision
        self.mergeBlockers = mergeBlockers
        self.headSHA = headSHA
        self.mergeMethods = mergeMethods
        self.checks = checks
        self.canMerge = canMerge
    }
}

/// The check runs rolled into counts, which is what a pull request body carries. The checks
/// endpoint says the same thing in its own summary with one field spelled differently; see
/// `CloudChecksSummary`.
public struct CloudChecksRollup: Decodable, Sendable, Hashable {
    public var total: Int
    public var passed: Int
    public var failed: Int
    public var pending: Int
    public var conclusion: String?

    public init(total: Int, passed: Int, failed: Int, pending: Int, conclusion: String? = nil) {
        self.total = total
        self.passed = passed
        self.failed = failed
        self.pending = pending
        self.conclusion = conclusion
    }
}

/// Every check on the branch's head commit, as runbloom.app last saw them.
///
/// Check runs and commit statuses arrive in one list, so a repository that reports either way reads
/// the same here.
public struct CloudChecks: Decodable, Sendable, Hashable {
    public var headSHA: String?
    public var summary: CloudChecksSummary
    public var checks: [CloudCheck]
    public var fetchedAt: Date?
    public var stale: Bool

    /// Whether GitHub has nothing to report, as opposed to this Mac not having been told. Checks
    /// that cannot be read are a refusal from runbloom.app rather than a snapshot saying so, which
    /// is why those two are drawn differently.
    public var isEmpty: Bool { summary.state == "none" && checks.isEmpty }

    enum CodingKeys: String, CodingKey {
        case summary, checks, stale
        case headSHA = "head_sha"
        case fetchedAt = "fetched_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        headSHA = try c.decodeIfPresent(String.self, forKey: .headSHA)
        summary = try c.decode(CloudChecksSummary.self, forKey: .summary)
        checks = try c.decodeIfPresent([CloudCheck].self, forKey: .checks) ?? []
        fetchedAt = try c.decodeIfPresent(RunbloomDate.self, forKey: .fetchedAt)?.date
        stale = try c.decodeIfPresent(Bool.self, forKey: .stale) ?? false
    }

    public init(headSHA: String? = nil, summary: CloudChecksSummary, checks: [CloudCheck] = [],
                fetchedAt: Date? = nil, stale: Bool = false) {
        self.headSHA = headSHA
        self.summary = summary
        self.checks = checks
        self.fetchedAt = fetchedAt
        self.stale = stale
    }
}

/// The counts, with `succeeded` where the pull request's rollup says `passed`. The two spellings
/// are runbloom.app's, and are kept apart here rather than papered over, so a reader of either
/// body sees the field that body really has.
public struct CloudChecksSummary: Decodable, Sendable, Hashable {
    public var state: String
    public var total: Int
    public var succeeded: Int
    public var failed: Int
    public var pending: Int
    public var skipped: Int

    public init(state: String, total: Int, succeeded: Int, failed: Int, pending: Int, skipped: Int) {
        self.state = state
        self.total = total
        self.succeeded = succeeded
        self.failed = failed
        self.pending = pending
        self.skipped = skipped
    }
}

public struct CloudCheck: Decodable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var status: String
    public var conclusion: String?
    public var detailsURL: String?
    public var startedAt: Date?
    public var completedAt: Date?
    public var summary: String?

    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion, summary
        case detailsURL = "details_url"
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        conclusion = try c.decodeIfPresent(String.self, forKey: .conclusion)
        detailsURL = try c.decodeIfPresent(String.self, forKey: .detailsURL)
        startedAt = try c.decodeIfPresent(RunbloomDate.self, forKey: .startedAt)?.date
        completedAt = try c.decodeIfPresent(RunbloomDate.self, forKey: .completedAt)?.date
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
    }

    public init(id: String, name: String, status: String, conclusion: String? = nil, detailsURL: String? = nil,
                startedAt: Date? = nil, completedAt: Date? = nil, summary: String? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.detailsURL = detailsURL
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.summary = summary
    }
}

/// How a merge is asked for. `headSHA` is sent so a branch that moved under what the reader was
/// looking at is refused with `head_changed` rather than merged on trust.
public struct CloudMergeRequest: Encodable, Sendable, Hashable {
    public var method: String
    public var commitTitle: String?
    public var commitMessage: String?
    public var headSHA: String?

    public init(method: String, commitTitle: String? = nil, commitMessage: String? = nil, headSHA: String? = nil) {
        self.method = method
        self.commitTitle = commitTitle
        self.commitMessage = commitMessage
        self.headSHA = headSHA
    }

    enum CodingKeys: String, CodingKey {
        case method
        case commitTitle = "commit_title"
        case commitMessage = "commit_message"
        case headSHA = "head_sha"
    }
}
