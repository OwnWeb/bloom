import BloomClient
import BloomCore
import Foundation
import SwiftUI

/// A new Cloud workspace being built, as the setup card draws it: which step it is on, since when,
/// and what can be done about it. See `CloudSetupProgress` for why this is one card from the
/// first second rather than a placeholder, a banner and a log in turn.
extension CloudWorkspaceSession {
    /// The build's steps, or nil when this workspace is not being built.
    ///
    /// **Before the machine has sent its setup record, only runbloom.app can say.** Every Cloud
    /// workspace has no record for the moment its connection takes to open, and a card that
    /// said "Creating the machine" over each of them for that moment would be a flash on every
    /// switch. runbloom.app's row says `setting_up` from the second the workspace is created, and
    /// it is the one fact that tells a machine being made from one being reached.
    var setupProgress: CloudSetupProgress? {
        let item = cloud.item(id)
        if state.setup == nil, item?.state != "setting_up" { return nil }
        return CloudSetupProgress.of(
            setup: state.setup, log: state.setupLog,
            isConnected: phase == .live, repository: item?.project?.repository
        )
    }

    /// The two starts known without having been watched: the machine was begun when the
    /// workspace was created, and the clone when the run started.
    var setupClockAnchors: [CloudSetupProgress.StepID: Date] {
        var anchors: [CloudSetupProgress.StepID: Date] = [:]
        anchors[.machine] = cloud.item(id)?.createdAt
        anchors[.clone] = state.setup?.startedAt
        return anchors
    }

    /// When the build as a whole began, for the time beside the card's title.
    var setupStartedAt: Date? { cloud.item(id)?.createdAt ?? state.setup?.startedAt }

    /// Records the step now running. Called from the card whenever it changes.
    func observeSetupStep(_ step: CloudSetupProgress.StepID?) {
        setupClock.observe(step, at: Date())
    }

    var showsSetupCard: Bool { setupProgress != nil }

    /// The card, for an empty pane: with the first message under it while that is still waiting
    /// here, because there is no conversation yet to draw it in.
    @ViewBuilder
    func setupCard() -> some View {
        if let progress = setupProgress {
            SetupCardPane {
                setupCard(progress, heldPrompt: heldPrompt?.text)
            }
        }
    }

    /// The card over this workspace's own state. Built here, so the view is handed values and can
    /// be drawn offscreen with none of a live session behind it: see `CloudSetupGallery`.
    func setupCard(_ progress: CloudSetupProgress, heldPrompt: String?) -> CloudSetupCard {
        let item = cloud.item(id)
        var actions = CloudSetupCard.Actions()
        actions.stepChanged = { [weak self] step in self?.observeSetupStep(step) }
        if allows("files") {
            actions.stop = { [weak self] in self?.stopSetup() }
            actions.runAgain = { [weak self] in self?.runSetupAgain() }
        }
        return CloudSetupCard(
            progress: progress,
            workspaceName: item?.displayName ?? "this workspace",
            item: item,
            clock: setupClock,
            anchors: setupClockAnchors,
            startedAt: setupStartedAt,
            log: state.setupLog,
            heldPrompt: heldPrompt,
            actions: actions
        )
    }

    func stopSetup() {
        Task { await run(.stopSetup) }
    }

    func runSetupAgain() {
        Task { await run(.runSetup) }
    }
}
