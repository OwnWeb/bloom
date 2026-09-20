import BloomClient
import BloomCore
import Foundation

/// runbloom.app's pull request and checks, as the strip and the Checks tab already draw them.
///
/// **Field copying and nothing else.** Every decision made from these values, what the band says,
/// which button it offers, what is blocking a merge, is `PullRequestStatus` in the core, shared
/// with a local workspace, and it is the reason the mapping is worth writing: a Cloud workspace's
/// band is then the same band rather than a second opinion about the same facts.
///
/// It lives in the app target because `BloomCore` cannot see `BloomClient` (the core is built for
/// the runner on Linux, where runbloom.app's API has no business being), so this is the one seam
/// where the two vocabularies meet. The decisions that are not field copying are in `BloomClient`
/// beside the records, where a test can reach them.
extension PullRequest {
    /// Nil when the branch has no pull request, which the same endpoint answers with three fields.
    init?(cloudState state: CloudPullRequestState) {
        guard state.hasPullRequest, let number = state.number else { return nil }
        self.init(
            number: number,
            title: state.title ?? "",
            url: state.url ?? "",
            // The core compares case-insensitively, so runbloom.app's lower case is left as it is.
            state: state.state ?? "open",
            isDraft: state.isDraft ?? false,
            // `conflicts` is runbloom.app's own reading of `mergeable_state`, and it is the one
            // the core's `hasConflicts` asks for. A `mergeable` of nil means GitHub has not worked
            // it out yet, which is not a conflict and must not be drawn as one.
            mergeable: state.conflicts == true ? "CONFLICTING" : state.mergeableState?.uppercased(),
            checks: Checks(cloudRollup: state.checks),
            checksSummary: CloudChecksWording.summary(state.checks),
            reviewDecision: state.reviewDecision,
            branch: state.headBranch
        )
    }
}

extension PullRequest.Checks {
    /// The rollup as the band's traffic light. Absent counts as unavailable rather than as none:
    /// "no checks" is a fact about the repository and "I was not told" is not.
    init(cloudRollup rollup: CloudChecksRollup?) {
        guard let rollup else { self = .unavailable; return }
        if rollup.total == 0 { self = .none } else if rollup.failed > 0 { self = .failing } else if rollup.pending > 0 {
            self = .pending
        } else {
            self = .passing
        }
    }
}

extension CheckRun {
    /// One check as the Checks tab draws it. Check runs and commit statuses arrive in one list on
    /// runbloom.app's side, so both read the same here.
    ///
    /// `workflowName` is nil: runbloom.app does not group by workflow, and inventing a group would
    /// put a heading over a list that never had one.
    init(cloudCheck check: CloudCheck) {
        self.init(
            name: check.name,
            status: check.status,
            conclusion: check.conclusion,
            detailsURL: check.detailsURL,
            startedAt: check.startedAt,
            completedAt: check.completedAt
        )
    }
}
