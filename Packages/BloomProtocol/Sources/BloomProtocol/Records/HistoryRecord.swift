import Foundation

/// One commit on the workspace's branch, as the History tab draws a row.
///
/// The same fields the Mac reads from `git log` for a local workspace, so one renderer serves both.
/// A commit's file list is not here: a page is a hundred rows and only the row somebody opens needs
/// its files, which `commit_files` answers for one commit.
public struct CommitRecord: Codable, Sendable, Hashable {
    public var sha: String
    public var subject: String
    public var authorName: String
    public var authorEmail: String
    public var date: Date
    public var body: String
    public var parents: [String]
    /// Whether the branch's remote has this commit. Nil when the branch has no remote yet, which
    /// is not the same as "not pushed".
    public var pushed: Bool?

    public init(sha: String, subject: String, authorName: String, authorEmail: String, date: Date,
                body: String, parents: [String], pushed: Bool? = nil) {
        self.sha = sha
        self.subject = subject
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.date = date
        self.body = body
        self.parents = parents
        self.pushed = pushed
    }

    enum CodingKeys: String, CodingKey {
        case sha, subject, date, body, parents, pushed
        case authorName = "author_name"
        case authorEmail = "author_email"
    }
}

/// A page of the branch's commits, newest first, from the base branch's merge base to HEAD.
public struct HistoryRecord: Codable, Sendable, Hashable {
    public var commits: [CommitRecord]
    /// Whether there are older commits than this page holds.
    public var hasMore: Bool

    public init(commits: [CommitRecord], hasMore: Bool) {
        self.commits = commits
        self.hasMore = hasMore
    }

    enum CodingKeys: String, CodingKey {
        case commits
        case hasMore = "has_more"
    }
}
