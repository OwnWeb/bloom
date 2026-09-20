import BloomCore
import BloomProtocol
import Foundation
import Observation

/// The branch's commits for a Cloud workspace, read from its machine a page at a time.
///
/// The machine measures them with the same `git log` a local workspace is measured with and hands
/// over `CommitRecord`s, so what the History tab draws is the rows it has always drawn. It also
/// says whether the branch's remote already has each commit, which nothing draws yet and which is
/// why `BranchCommit` does not carry it.
///
/// **Paged rather than limited.** A local workspace asks git again with a larger limit, because
/// asking git twice costs nothing. A machine is on the other side of a network and may be asleep,
/// so Load earlier commits asks for what comes after the oldest row on screen and appends it.
@MainActor
@Observable
final class CloudHistory {
    private(set) var commits = BranchCommitList()
    private(set) var hasRead = false
    private(set) var problem: String?

    @ObservationIgnored private weak var session: CloudWorkspaceSession?
    /// One read at a time. Load earlier commits is a button somebody can hit twice, and two pages
    /// in flight from the same cursor would append the same commits twice.
    @ObservationIgnored private var isReading = false

    /// A page, in rows. Fifty is what the local History tab shows before it offers more.
    private static let page = BranchCommitList.limit

    init(session: CloudWorkspaceSession) {
        self.session = session
    }

    /// The newest page, read again from the top. Called when the tab opens and when the machine
    /// says the review moved, which is when a commit can have appeared.
    func refresh() async {
        guard let session, !isReading else { return }
        isReading = true
        defer { isReading = false }
        do {
            let result = try await session.perform(.history(limit: Self.page, before: nil))
            guard case .history(let record) = result else { return }
            let read = BranchCommitList(commits: record.commits.map(BranchCommit.init(cloudRecord:)), isTruncated: record.hasMore)
            if commits != read { commits = read }
            hasRead = true
            problem = nil
        } catch {
            problem = "Could not read the commit history. \(error.message)"
            hasRead = true
        }
    }

    /// The page after the oldest row on screen, appended. Nothing happens when there is no more.
    func loadMore() async {
        guard let session, !isReading, commits.isTruncated, let oldest = commits.commits.last else { return }
        isReading = true
        defer { isReading = false }
        do {
            let result = try await session.perform(.history(limit: Self.page, before: oldest.sha))
            guard case .history(let record) = result else { return }
            // Appended by sha rather than blindly, so a page read twice cannot draw a commit twice.
            let known = Set(commits.commits.map(\.sha))
            let older = record.commits.map(BranchCommit.init(cloudRecord:)).filter { !known.contains($0.sha) }
            commits = BranchCommitList(commits: commits.commits + older, isTruncated: record.hasMore)
            problem = nil
        } catch {
            problem = "Could not read earlier commits. \(error.message)"
        }
    }
}
