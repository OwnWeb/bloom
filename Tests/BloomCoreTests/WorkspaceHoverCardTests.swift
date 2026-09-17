import CoreGraphics
import Foundation
import Testing
@testable import BloomCore

/// What the card beside a hovered sidebar row says, how wide it comes out, and where it is put.
///
/// Every date here is built rather than read off the clock, for the reason `HomeListTests` writes
/// down: a suite that says "six days ago" as an offset from `Date()` passes all afternoon and
/// fails at midnight.
@Suite("Workspace hover card")
struct WorkspaceHoverCardTests {
    /// The clock every case below is measured from. A fixed instant, so "6d ago" is 6d ago on
    /// every machine that runs this and in every month.
    static let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func workspace(
        name: String = "Add a hover card to the sidebar",
        branch: String = "freek/hover-card",
        additions: Int = 0,
        deletions: Int = 0,
        changedFiles: Int = 0,
        unread: Bool = false,
        lastActivityAt: Date = WorkspaceHoverCardTests.now
    ) -> Workspace {
        Workspace(
            repoID: RepoID("repo"),
            name: name,
            branch: branch,
            path: "/tmp/worktree",
            baseBranch: "main",
            createdAt: lastActivityAt,
            lastActivityAt: lastActivityAt,
            additions: additions,
            deletions: deletions,
            changedFiles: changedFiles,
            unread: unread
        )
    }

    private func pullRequest(
        number: Int = 362,
        state: String = "OPEN",
        checks: PullRequest.Checks = .none,
        checksSummary: String = "",
        isDraft: Bool = false
    ) -> PullRequest {
        PullRequest(
            number: number,
            title: "Add a hover card to the sidebar",
            url: "https://github.com/spatie/bloom/pull/\(number)",
            state: state,
            isDraft: isDraft,
            checks: checks,
            checksSummary: checksSummary
        )
    }

    // MARK: - What it says

    @Test("A changed workspace with no pull request says so and shows its counts")
    func changedWithoutPullRequest() {
        let card = WorkspaceHoverCard.make(
            workspace: workspace(additions: 1_418, deletions: 556, changedFiles: 12),
            now: Self.now
        )

        #expect(card.title == "Add a hover card to the sidebar")
        #expect(card.branch == "freek/hover-card")
        #expect(card.diff == WorkspaceHoverCard.Diff(additions: 1_418, deletions: 556))
        #expect(card.status == .changed)
        #expect(card.state == "Has changes")
        #expect(card.detail == nil)
        #expect(card.pullRequest == nil)
    }

    /// The empty case, and the reason `diff` is optional rather than two zeroes: "+0 -0" is a
    /// line that says nothing. The state carries the fact instead, which is why nothing is drawn
    /// where the counts would be.
    @Test("A workspace with nothing changed carries no counts at all")
    func noChanges() {
        let card = WorkspaceHoverCard.make(workspace: workspace(), now: Self.now)

        #expect(card.diff == nil)
        #expect(card.status == .clean)
        #expect(card.state == "No changes")
    }

    /// Files touched without a line changing, which is what a rename or a mode change is. The
    /// card follows `Workspace.hasDiff` rather than `changedFiles`, so it holds exactly the
    /// opinion the row's own counts hold: two files and nothing to count is not a diff.
    @Test("Changed files with no changed lines draw no counts")
    func zeroLineDiff() {
        let card = WorkspaceHoverCard.make(
            workspace: workspace(changedFiles: 2), now: Self.now
        )

        #expect(card.status == .clean)
        #expect(card.diff == nil)
    }

    @Test("Failing checks put the count behind the state rather than in place of it")
    func failingChecks() {
        let card = WorkspaceHoverCard.make(
            workspace: workspace(additions: 40, deletions: 3, changedFiles: 2),
            pullRequest: pullRequest(
                checks: .failing, checksSummary: "1 of 12 checks failed"
            ),
            now: Self.now
        )

        #expect(card.status == .checksFailing)
        #expect(card.state == "Checks failing")
        #expect(card.detail == "1 of 12 checks failed")
        #expect(card.pullRequest?.number == 362)
        #expect(card.pullRequest?.url == "https://github.com/spatie/bloom/pull/362")
    }

    /// gh reports its own rollup summary, and for a failing run it is often the same three words
    /// the state is already drawn in. The card must not say it twice.
    @Test("A rollup summary equal to the state is not repeated under it")
    func detailThatRepeatsTheState() {
        let card = WorkspaceHoverCard.make(
            workspace: workspace(additions: 40, deletions: 3, changedFiles: 2),
            pullRequest: pullRequest(checks: .failing, checksSummary: "Checks failing"),
            now: Self.now
        )

        #expect(card.state == "Checks failing")
        #expect(card.detail == nil)
    }

    /// The state is about now and the number is about the branch. Suppressing the number while a
    /// turn runs would blink it out at the one moment somebody most wants to see it.
    @Test("A running agent keeps the pull request number under a running state")
    func runningKeepsItsPullRequest() {
        let card = WorkspaceHoverCard.make(
            workspace: workspace(additions: 12, deletions: 1, changedFiles: 1),
            isRunning: true,
            pullRequest: pullRequest(checks: .passing, checksSummary: "12 checks passed"),
            now: Self.now
        )

        #expect(card.status == .running)
        #expect(card.state == "Agent running")
        // The detail belongs to the pull request's state, and the state on show is not the pull
        // request's, so there is nothing to put behind it.
        #expect(card.detail == nil)
        #expect(card.pullRequest?.number == 362)
    }

    @Test("A blocked agent outranks everything else the row could say")
    func awaitingPermission() {
        let card = WorkspaceHoverCard.make(
            workspace: workspace(additions: 4, deletions: 0, changedFiles: 1, unread: true),
            isRunning: true,
            isAwaitingPermission: true,
            now: Self.now
        )

        #expect(card.status == .awaitingPermission)
        #expect(card.state == "Waiting on you")
    }

    // MARK: - The two things the row cannot draw

    /// The card exists because the row truncates. Shortening the name here as well would leave
    /// the whole affordance with nothing to add.
    @Test("A title far too long for the row is carried whole")
    func longTitle() {
        let long = "Show me every place the technologies used in this project are configured, "
            + "and say which of them are pinned to a version"
        let card = WorkspaceHoverCard.make(workspace: workspace(name: long), now: Self.now)

        #expect(card.title == long)
        #expect(card.title.count == long.count)
    }

    /// Never reduced to its last component: `freek/fix-checks` and `agent/fix-checks` would then
    /// draw the same line on two different workspaces.
    @Test("A branch with slashes in it keeps all of them")
    func branchWithSlashes() {
        let card = WorkspaceHoverCard.make(
            workspace: workspace(branch: "agent/2026-08/fix-the-checks"), now: Self.now
        )

        #expect(card.branch == "agent/2026-08/fix-the-checks")
    }

    // MARK: - Age

    @Test("Six days reads as the phrase, not as the measurement")
    func sixDaysAgo() {
        let card = WorkspaceHoverCard.make(
            workspace: workspace(lastActivityAt: Self.now.addingTimeInterval(-6 * 86_400)),
            now: Self.now
        )

        #expect(card.age == "6d ago")
    }

    /// A workspace nobody has touched since it was cut. `lastActivityAt` equals `createdAt`,
    /// which is the clock, and "now ago" is not English.
    @Test("A workspace that has never been touched reads as just now")
    func neverTouched() {
        let card = WorkspaceHoverCard.make(workspace: workspace(), now: Self.now)

        #expect(card.age == "just now")
    }

    /// A clock change or a restore from a backup produces a timestamp in the future. `HomeAge`
    /// already decided what to say about it, and the phrase must not invent a second answer.
    @Test("A timestamp from the future reads as just now rather than as a negative age")
    func futureTimestamp() {
        let card = WorkspaceHoverCard.make(
            workspace: workspace(lastActivityAt: Self.now.addingTimeInterval(3_600)),
            now: Self.now
        )

        #expect(card.age == "just now")
    }

    /// Every rung of `HomeAge`'s scale, so a change to one of its thresholds cannot quietly
    /// change what the card reads. Written out as a typed property rather than as a literal in
    /// the macro's argument list, which on its own was enough to time the type checker out
    /// inside the `@Test` expansion.
    static let ageRungs: [(seconds: Double, phrase: String)] = [
        (30, "just now"),
        (600, "10m ago"),
        (7_200, "2h ago"),
        (86_400 * 3, "3d ago"),
        (86_400 * 14, "2w ago"),
        (86_400 * 90, "3mo ago"),
        (86_400 * 800, "2y ago"),
    ]

    @Test("Every rung of the age scale gains the word", arguments: ageRungs)
    func agePhrases(rung: (seconds: Double, phrase: String)) {
        let card = WorkspaceHoverCard.make(
            workspace: workspace(lastActivityAt: Self.now.addingTimeInterval(-rung.seconds)),
            now: Self.now
        )

        #expect(card.age == rung.phrase)
    }

    // MARK: - How wide it comes out

    /// The card the width of its content, which is the whole change: a branch called
    /// `freekmurze/review-support-question` used to be drawn `…eekmurze/review-support-question`
    /// inside a card that was 320 points whatever was on it.
    @Test("Content between the two bounds is drawn at its own width")
    func widthFollowsTheContent() {
        #expect(HoverCardWidth.fits(content: 412) == 412)
    }

    /// The floor, which is what the fixed width became. A workspace called `x` on a branch called
    /// `x` is a card, not a small square.
    @Test("Content narrower than the floor is drawn at the floor")
    func widthNeverGoesBelowTheFloor() {
        #expect(HoverCardWidth.fits(content: 120) == HoverCardWidth.minimum)
        #expect(HoverCardWidth.fits(content: 0) == HoverCardWidth.minimum)
    }

    /// And the ceiling, past which truncating is the right answer. A card as wide as the longest
    /// branch anybody can type is worse than a truncated one.
    @Test("Content wider than the ceiling is drawn at the ceiling")
    func widthNeverGoesAboveTheCeiling() {
        #expect(HoverCardWidth.fits(content: 900) == HoverCardWidth.ceiling)
    }

    /// A text layout answers in fractions and a panel on a half point draws its rim across two
    /// rows of pixels. Rounded up rather than down, so the rounding never costs a character.
    @Test("A fractional width is rounded up to a whole point")
    func widthIsWhole() {
        #expect(HoverCardWidth.fits(content: 412.25) == 413)
    }

    /// `NSHostingView.fittingSize` answers zero for a view that has not laid out, and has been
    /// seen to answer worse than that. Neither is a width, and a panel given one would be a
    /// shadow with nothing in it.
    @Test("A width that is not a number lands on the floor")
    func widthOfNothingAtAll() {
        #expect(HoverCardWidth.fits(content: .nan) == HoverCardWidth.minimum)
        #expect(HoverCardWidth.fits(content: .infinity) == HoverCardWidth.minimum)
    }

    /// The floor has to leave the ceiling somewhere to go, and the ceiling has to be a card rather
    /// than a pane. Written as a test because both are read by four cards in two targets.
    @Test("The bounds are the right way round and neither is a pane")
    func boundsAreSane() {
        #expect(HoverCardWidth.minimum < HoverCardWidth.ceiling)
        #expect(HoverCardWidth.minimum > 260)
    }
}
