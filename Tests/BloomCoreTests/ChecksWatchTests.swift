import Testing
import Foundation
@testable import BloomCore

/// Which workspaces the checks notification asks about, and what it calls news.
///
/// The bug behind the suite: the watcher rode on `AppModel.existingModel(for:)`, so a workspace
/// with no `WorkspaceModel` was not watched. Nothing has a model until it is opened, so after a
/// relaunch the feature watched nothing at all while Settings said it was on. The second half was
/// quieter: the announcement needed a previous reading of `.pending` and those readings lived in
/// memory, so a run that finished while Bloom was shut had nothing to move from.
@Suite("Checks watch")
struct ChecksWatchTests {
    // MARK: - Who gets asked

    /// The case the whole change is for. No previous reading is not a reason to skip a workspace,
    /// it is a reason to take the first one.
    @Test("a workspace nothing has read yet is asked about once")
    func unknownIsAsked() {
        #expect(ChecksWatch.polls(hasPullRequest: true, lastSeen: nil, isOnScreen: false))
    }

    @Test("a pull request with checks in flight keeps being asked about")
    func pendingIsAsked() {
        #expect(ChecksWatch.polls(hasPullRequest: true, lastSeen: .pending, isOnScreen: false))
    }

    /// The cost argument, as a test. Each ask is a `gh` subprocess, so a settled answer is never
    /// asked for twice.
    @Test("a settled pull request is not asked about again", arguments: [
        PullRequest.Checks.passing, .failing, .none, .unavailable,
    ])
    func settledIsNotAsked(_ settled: PullRequest.Checks) {
        #expect(!ChecksWatch.polls(hasPullRequest: true, lastSeen: settled, isOnScreen: false))
    }

    /// A branch with no pull request cannot have a check run, so asking spends a subprocess on a
    /// certainty. This is what keeps a project full of fresh workspaces from costing anything.
    @Test("a workspace with no pull request is never asked about")
    func noPullRequestIsNeverAsked() {
        #expect(!ChecksWatch.polls(hasPullRequest: false, lastSeen: nil, isOnScreen: false))
        #expect(!ChecksWatch.polls(hasPullRequest: false, lastSeen: .pending, isOnScreen: false))
    }

    /// The workspace being looked at refreshes itself, and is the one nobody needs a banner about.
    @Test("the workspace on screen is left alone")
    func onScreenIsLeftAlone() {
        #expect(!ChecksWatch.polls(hasPullRequest: true, lastSeen: .pending, isOnScreen: true))
        #expect(!ChecksWatch.polls(hasPullRequest: true, lastSeen: nil, isOnScreen: true))
    }

    // MARK: - What counts as news

    @Test("a run that finishes is announced", arguments: [PullRequest.Checks.passing, .failing])
    func finishingIsAnnounced(_ outcome: PullRequest.Checks) {
        #expect(ChecksWatch.announces(from: .pending, to: outcome))
    }

    /// The half that survives a relaunch. The previous reading is on disk, so a run that finished
    /// while Bloom was shut is still a move from pending when the app comes back.
    @Test("a run that finished while Bloom was shut is still a transition")
    func aStoredPendingStillAnnounces() {
        // Exactly the call the watcher makes on its first pass of a new launch, with the baseline
        // read back from the settings row rather than from memory.
        let stored = PullRequest.Checks(rawValue: PullRequest.Checks.pending.rawValue)
        #expect(ChecksWatch.announces(from: stored, to: .passing))
    }

    /// The old rule, kept word for word: only the transition, never the state.
    @Test("a pull request green since yesterday says nothing")
    func settledStateIsNotNews() {
        #expect(!ChecksWatch.announces(from: .passing, to: .passing))
        #expect(!ChecksWatch.announces(from: .failing, to: .failing))
        #expect(!ChecksWatch.announces(from: .passing, to: .failing))
    }

    /// Announcing off a first reading would mean a project added this morning firing a banner for
    /// every green pull request in it. Silent once per workspace is the price of never being
    /// wrong in a burst.
    @Test("nothing is announced from no previous reading", arguments: [
        PullRequest.Checks.passing, .failing, .pending, .none, .unavailable,
    ])
    func nothingIsAnnouncedFromNothing(_ now: PullRequest.Checks) {
        #expect(!ChecksWatch.announces(from: nil, to: now))
    }

    /// `.unavailable` is GitHub refusing this token the checks, not a run finishing, and `.none`
    /// is a fact about the repository. A banner for either would be a claim nobody made.
    @Test("a state that is not an outcome is not announced", arguments: [
        PullRequest.Checks.none, .unavailable, .pending,
    ])
    func nonOutcomesAreNotAnnounced(_ now: PullRequest.Checks) {
        #expect(!ChecksWatch.announces(from: .pending, to: now))
    }

    // MARK: - Where the reading is kept

    /// The key has to be per workspace and stable, because it is what carries the baseline across
    /// a relaunch. Two workspaces sharing one would announce each other's runs.
    @Test("each workspace writes its reading down under its own key")
    func keysAreStableAndDistinct() {
        let one = ChecksWatch.lastSeenKey(workspaceID: WorkspaceID("abc"))
        let two = ChecksWatch.lastSeenKey(workspaceID: WorkspaceID("def"))

        #expect(one == "checks.lastSeen.abc")
        #expect(one != two)
        #expect(one == ChecksWatch.lastSeenKey(workspaceID: WorkspaceID("abc")))
    }

    /// The stored value is the enum's own raw value, so a reading written by one launch is read
    /// back by the next. A rename of a case would break this, which is what the test is for.
    @Test("a reading survives being written down and read back", arguments: [
        PullRequest.Checks.pending, .passing, .failing, .none, .unavailable,
    ])
    func readingsRoundTripThroughASetting(_ checks: PullRequest.Checks) {
        #expect(PullRequest.Checks(rawValue: checks.rawValue) == checks)
    }
}
