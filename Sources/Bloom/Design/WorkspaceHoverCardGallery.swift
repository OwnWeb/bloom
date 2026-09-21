import SwiftUI
import BloomCore

/// The card that opens under the pull request band, in representative states.
///
/// The card is drawn in a popover (see `hoverPopover`), which no probe in this folder can
/// photograph and which no pointer a capture run has can raise. What CAN be photographed is the
/// card itself, and that is what is worth looking at: the states are all differences of content,
/// so a page of them side by side answers every question except where the popover lands, and that
/// is AppKit's.
///
/// Each pane is the card at the width its content asks for. The long branch should be the widest
/// thing here without reaching `HoverCardWidth.ceiling`.
///
///     Bloom --snapshot-gallery <dir> --gallery hover-card
struct WorkspaceHoverCardGallery: View {
    /// A fixed clock, so "6d ago" is six days ago in every capture rather than however long it is
    /// since somebody wrote this file.
    private static let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func workspace(
        name: String,
        branch: String,
        additions: Int = 0,
        deletions: Int = 0,
        unread: Bool = false,
        daysAgo: Double = 0
    ) -> Workspace {
        let touched = Self.now.addingTimeInterval(-daysAgo * 86_400)
        return Workspace(
            repoID: RepoID("bloom"),
            name: name,
            branch: branch,
            path: "/tmp/worktree",
            baseBranch: "main",
            createdAt: touched,
            lastActivityAt: touched,
            additions: additions,
            deletions: deletions,
            changedFiles: additions + deletions > 0 ? 12 : 0,
            unread: unread
        )
    }

    private func pullRequest(
        number: Int = 362,
        state: String = "OPEN",
        checks: PullRequest.Checks,
        summary: String,
        isDraft: Bool = false
    ) -> PullRequest {
        PullRequest(
            number: number,
            title: "Add a hover card to the sidebar",
            url: "https://github.com/spatie/bloom/pull/\(number)",
            state: state,
            isDraft: isDraft,
            checks: checks,
            checksSummary: summary
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.pane) {
            HStack(alignment: .top, spacing: Metrics.pane) {
                pane("No pull request yet", bandCard(
                    workspace(
                        name: "Answer a review support question",
                        branch: "freekmurze/review-support-question",
                        additions: 1_418,
                        deletions: 556,
                        daysAgo: 0.2
                    )
                ))
                pane("Checks failing", bandCard(
                    workspace(
                        name: "Fix the flaky diff parser test",
                        branch: "agent/2026-08/fix-the-flaky-diff-parser-test",
                        additions: 42,
                        deletions: 9,
                        daysAgo: 1
                    ),
                    pullRequest: pullRequest(
                        checks: .failing, summary: "1 of 12 required checks failed"
                    )
                ))
                pane("Merged", bandCard(
                    workspace(
                        name: "Draw a file path in a sent turn as a file",
                        branch: "chat/file-pill-and-merge-scroll",
                        daysAgo: 30
                    ),
                    pullRequest: pullRequest(
                        number: 23, state: "MERGED", checks: .passing, summary: "12 checks passed"
                    )
                ))
            }
        }
        .padding(Metrics.pane)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The ground the card is judged against is whatever it floats over, which in the window is
        // the centre column rather than the sidebar. The panel's material is `.behindWindow` and
        // has nothing to blend with offscreen, so this is the honest half of the picture: the
        // layout, the ink and the truncation.
        .background(Palette.windowBackground)
    }

    private func bandCard(
        _ workspace: Workspace,
        pullRequest: PullRequest? = nil
    ) -> WorkspaceHoverCard {
        WorkspaceHoverCard.pullRequestBand(
            workspace: workspace,
            pullRequest: pullRequest,
            now: Self.now
        )
    }

    private func pane(_ title: String, _ card: WorkspaceHoverCard) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingWide) {
            Text(title)
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)

            // Drawn exactly as the panel draws it, rim and material and all, and with no shadow,
            // because the shadow is the panel's rather than the card's. No frame around it: the
            // card sizes itself now, so a pane that pinned it to a width would be the one place
            // in this app where it did not. Which pane is widest is the thing to look at.
            WorkspaceHoverCardView(card: card)
        }
    }
}

extension Gallery {
    /// The registry entry for this page. See `Gallery`.
    ///
    /// Three cards, each at the width its own content asks for.
    static let hoverCard = Gallery(
        name: "hover-card",
        title: "Pull request hover card",
        size: CGSize(width: 1_440, height: 320),
        needsFocus: false,
        view: { _ in AnyView(WorkspaceHoverCardGallery()) }
    )
}
