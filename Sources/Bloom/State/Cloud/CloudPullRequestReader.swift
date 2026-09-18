import BloomClient
import BloomCore
import Foundation
import Observation

/// What GitHub says about a Cloud workspace's branch, read from runbloom.app.
///
/// **runbloom.app asks GitHub, not this Mac.** A Cloud workspace's branch may be in a repository
/// this Mac's `gh` has never been signed in to, and the machine has its own credentials; so the
/// band, the Checks tab, Mark ready for review and Merge all go through runbloom.app's GitHub App,
/// as the signed-in person.
///
/// **What it answers is up to a minute old.** A scheduled refresh on runbloom.app's side writes the
/// state every minute and the body says when it was fetched, so nothing here polls harder in the
/// hope of something fresher, and the strip says how old the answer is rather than implying it is
/// live. See `CloudChecksWording.freshness`.
@MainActor
@Observable
final class CloudPullRequestReader {
    private(set) var state: CloudPullRequestState?
    private(set) var checks: CloudChecks?
    private(set) var isLoading = false
    /// The last refusal, for the strip that says it is showing an older answer. Cleared by the
    /// next read that works.
    private(set) var failure: GitHubReadFailure?
    /// Set while the reader has put a failure in front of somebody and they have closed it. The
    /// same failure stays hidden; a different one, or a success, brings the strip back.
    private(set) var dismissedFailure: GitHubReadFailure?
    /// What the strip just did, said in the column under it: a refusal from runbloom.app, or a
    /// prompt that could not be sent. The strip writes it and the inspector draws it, for a Cloud
    /// workspace exactly as for a local one.
    var notice: PullRequestNotice?

    @ObservationIgnored private weak var session: CloudWorkspaceSession?
    @ObservationIgnored private var readAt: Date?
    @ObservationIgnored private var reading: Task<Void, Never>?

    init(session: CloudWorkspaceSession) {
        self.session = session
        method = MergeMethodChoice.fallback
        if let stored = UserDefaults.standard.string(forKey: Self.methodKey(session.id)),
           let remembered = GitHub.MergeMethod(rawValue: stored) {
            method = remembered
        }
    }

    /// The merge method this workspace merges with. Per workspace here, where a local one keeps it
    /// per project: a Cloud workspace's project lives on runbloom.app and this Mac has no row for
    /// it, so the nearest honest place is the workspace the reader is standing in.
    private(set) var method: GitHub.MergeMethod

    private static func methodKey(_ id: CloudWorkspaceID) -> String { "cloud.mergeMethod.\(id.rawValue)" }

    /// The methods the repository allows, or all three when runbloom.app has not said.
    var allowedMethods: [GitHub.MergeMethod] {
        guard let allowed = state?.mergeMethods, !allowed.isEmpty else { return GitHub.MergeMethod.allCases }
        let read = allowed.compactMap(GitHub.MergeMethod.init(rawValue:))
        return read.isEmpty ? GitHub.MergeMethod.allCases : read
    }

    func choose(_ method: GitHub.MergeMethod) {
        guard let session else { return }
        self.method = method
        UserDefaults.standard.set(method.rawValue, forKey: Self.methodKey(session.id))
    }

    /// Reads the pull request, unless the last answer is younger than `maxAge`.
    ///
    /// One read at a time, and the caller waits for the one in flight rather than starting a
    /// second: the band polls every twenty seconds and the Checks tab does too, over an answer
    /// that only changes once a minute.
    func refresh(maxAge: Duration) async {
        // Never harder than the state changes. The band polls every twenty seconds, which is right
        // for a local workspace asking `gh` itself; runbloom.app rewrites this on a schedule once a
        // minute, so asking three times inside one of its refreshes is three times the requests for
        // the same answer. The floor is under a minute so the first ask after a change is not a
        // whole cycle late.
        let floor = max(maxAge, .seconds(45))
        if let readAt, Date().timeIntervalSince(readAt) < floor.seconds { return }
        if let reading {
            await reading.value
            return
        }
        let task = Task { await read() }
        reading = task
        await task.value
        reading = nil
    }

    private func read() async {
        guard let session else { return }
        let cloud = session.cloud
        isLoading = true
        defer { isLoading = false }
        do {
            let answer = try await cloud.api.pullRequest(for: session.id.rawValue)
            state = answer
            readAt = Date()
            failure = nil
            dismissedFailure = nil
        } catch let refusal as RunbloomRefusal {
            note(GitHubReadFailure(reason: refusal.status == 403 ? .authentication : .unavailable, message: refusal.message))
        } catch {
            note(GitHubReadFailure(reason: .unavailable, message: "runbloom.app could not be reached."))
        }
    }

    /// The branch's checks, read on the same terms. Nil means they could not be read at all, which
    /// the Checks tab draws differently from a branch with no checks on it.
    func readChecks() async -> CloudChecks? {
        guard let session else { return nil }
        let cloud = session.cloud
        do {
            let answer = try await cloud.api.checks(for: session.id.rawValue)
            checks = answer
            return answer
        } catch {
            return nil
        }
    }

    func dismissFailure() {
        dismissedFailure = failure
    }

    /// The failure worth putting in front of somebody: the last one, unless it is the one they
    /// have already closed. The same rule `WorkspaceModel` follows for a local workspace.
    var visibleFailure: GitHubReadFailure? {
        guard let failure, failure != dismissedFailure else { return nil }
        return failure
    }

    // MARK: Acting on it, as the signed-in person

    /// Takes it out of draft. Answers nil, or what runbloom.app said, in its own words.
    func markReady() async -> String? {
        guard let session else { return "This Cloud workspace is closed." }
        let cloud = session.cloud
        do {
            state = try await cloud.api.markPullRequestReady(session.id.rawValue)
            readAt = Date()
            return nil
        } catch let refusal as RunbloomRefusal {
            return refusal.message
        } catch {
            return "runbloom.app could not be reached."
        }
    }

    /// Merges it. The head commit is sent with the request, so a branch that moved under what the
    /// reader was looking at is refused rather than merged on trust.
    func merge(_ method: GitHub.MergeMethod) async -> String? {
        guard let session else { return "This Cloud workspace is closed." }
        let cloud = session.cloud
        do {
            state = try await cloud.api.mergePullRequest(
                session.id.rawValue,
                request: CloudMergeRequest(method: method.rawValue, headSHA: state?.headSHA)
            )
            readAt = Date()
            return nil
        } catch let refusal as RunbloomRefusal {
            return refusal.message
        } catch {
            return "runbloom.app could not be reached."
        }
    }

    private func note(_ read: GitHubReadFailure) {
        failure = read
        // A failure that is not the one already closed is news, and the strip should say it.
        if dismissedFailure != read { dismissedFailure = nil }
    }
}
