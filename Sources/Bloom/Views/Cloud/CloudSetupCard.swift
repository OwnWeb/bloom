import BloomClient
import BloomCore
import SwiftUI

/// A new Cloud workspace being built: its name, where it comes from, the steps with the current
/// one alive, and the log folded away underneath.
///
/// **The same card from the first second to the first answer.** It is drawn in an empty pane
/// while the machine is being made, and at the head of the conversation once the machine has made
/// its first chat, in the same column at the same height, so the handover is a composer arriving
/// under it rather than one screen replaced by another. What it says is `CloudSetupProgress`'s,
/// which is where the steps, the line under the current one and the failure are decided and tested.
///
/// **The log is a disclosure, not the view.** It used to be the whole of what a new workspace
/// showed: a growing block of script output that turned into a card half way through and then
/// began losing its first lines. The steps are what somebody waiting wants; the log is for finding
/// out why, so it is open by itself only when something failed.
struct CloudSetupCard: View {
    private static let timingColumnWidth: CGFloat = 520

    /// What the card's buttons do, and who it tells when the step changes. Nil where the reader
    /// may not, which draws no button rather than one that is refused.
    struct Actions {
        var stop: (@MainActor () -> Void)?
        var runAgain: (@MainActor () -> Void)?
        var stepChanged: @MainActor (CloudSetupProgress.StepID?) -> Void = { _ in }
    }

    var progress: CloudSetupProgress
    /// Where the workspace comes from, for the line under the title.
    var item: CloudWorkspaceItem?
    var clock: CloudSetupClock
    var anchors: [CloudSetupProgress.StepID: Date]
    /// When the build began, for the time beside the title.
    var startedAt: Date?
    var log: String
    /// The first message typed at create and not yet sent, drawn under the steps while there is no
    /// conversation to draw it in. Nil at the head of a conversation, which draws its own.
    var heldPrompt: String?
    var actions = Actions()
    /// Whether the log is open, when the card sits in the transcript and the list holds that.
    /// See `WorkspaceEventsView.setupLogOpen` for why the card's own state cannot be trusted there.
    var heldLogOpen: Bool?
    /// Writes `heldLogOpen`. Nil in an empty pane, where the card keeps its own.
    var setLogOpen: (@MainActor (Bool) -> Void)?

    @State private var isLogOpen: Bool?

    private var logIsOpen: Bool {
        (setLogOpen == nil ? isLogOpen : heldLogOpen) ?? progress.opensLogAtFirst
    }

    private func toggleLog() {
        let open = !logIsOpen
        if let setLogOpen {
            setLogOpen(open)
        } else {
            withAnimation(Motion.pane) { isLogOpen = open }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            steps
                .padding(.top, Metrics.pane)
            controls
            if let heldPrompt {
                CloudSetupHeldPrompt(text: heldPrompt)
                    .padding(.top, Metrics.pane)
            }
            if LogTail.hasSomethingToShow(log) {
                Divider()
                    .padding(.top, Metrics.pane)
                logDisclosure
            }
        }
        .padding(.horizontal, TranscriptLayout.inset)
        .padding(.bottom, Metrics.pane)
        .onChange(of: progress.activeStep, initial: true) { _, step in
            actions.stepChanged(step)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.gutter) {
                Text(progress.title)
                    .font(Typo.heading)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Metrics.gutter)
                if progress.isBuilding, let startedAt {
                    CloudSetupElapsed(since: startedAt)
                        .help("How long this workspace has been setting up")
                }
            }
            .frame(maxWidth: Self.timingColumnWidth, alignment: .leading)
            if let item {
                origin(item)
            }
        }
    }

    /// Where the workspace comes from: the project, its branch, and the branch it started from.
    private func origin(_ item: CloudWorkspaceItem) -> some View {
        HStack(alignment: .center, spacing: Metrics.spacing) {
            if let project = item.project {
                CloudProjectIcon(
                    teamID: CloudTeamID(item.teamID),
                    projectID: CloudProjectID(project.id),
                    repository: project.repository,
                    iconURL: project.iconURL,
                    size: Metrics.repoIconSmall
                )
            }
            Text(originLine(item))
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func originLine(_ item: CloudWorkspaceItem) -> AttributedString {
        var line = AttributedString()
        if let repository = item.project?.repository {
            line += AttributedString(repository + " on ")
        }
        var branch = AttributedString(item.displayBranch)
        branch.font = .system(.callout, design: .monospaced)
        line += branch
        line += AttributedString(", from ")
        var base = AttributedString(item.baseBranch)
        base.font = .system(.callout, design: .monospaced)
        line += base
        return line
    }

    // MARK: - Steps

    private var steps: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(progress.steps.enumerated()), id: \.element.id) { index, step in
                CloudSetupStepRow(
                    step: step,
                    isLast: index == progress.steps.count - 1,
                    activity: step.state == .current ? progress.activity : nil,
                    lastOutput: step.state == .current ? progress.lastOutput : nil,
                    duration: clock.duration(of: step.id, anchors: anchors),
                    startedAt: step.state == .current && step.id != .machine
                        ? clock.start(of: step.id, anchors: anchors) : nil
                )
            }
        }
        .frame(maxWidth: Self.timingColumnWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What Bloom is doing")
    }

    // MARK: - Actions

    @ViewBuilder
    private var controls: some View {
        if let note = progress.failureNote {
            Text(note)
                .font(Typo.codeSmall)
                .foregroundStyle(Palette.negative)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Metrics.inset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.negative.opacity(0.08), in: .rect(cornerRadius: Metrics.corner))
                .padding(.top, Metrics.gutter)
        }
        if progress.kind == .failed, progress.canRunAgain, let runAgain = actions.runAgain {
            Button("Run Setup Again") { runAgain() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, Metrics.gutter)
        } else if progress.canStop, let stop = actions.stop {
            // **A bordered button on the step list's own edge, where it was grey words indented
            // under the last step.** The owner read it as that step's detail line, as though
            // stopping belonged to "Starting services", and did not read it as a button at all.
            // It stops the whole setup, so it sits where Run Setup Again sits once a run has
            // failed, and it is drawn the way the transcript's setup row draws the same verb.
            // Bordered rather than prominent: stopping is the exception, not the way forward.
            // No confirmation: stopping costs nothing that Run Setup Again cannot give back.
            Button("Stop setup") { stop() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(Typo.caption)
                .padding(.top, Metrics.gutter)
                .help("Stops the setup script. Anything waiting for it goes to the agent.")
        }
    }

    // MARK: - Log

    private var logDisclosure: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingWide) {
            Button {
                toggleLog()
            } label: {
                HStack(spacing: Metrics.spacing) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(logIsOpen ? 90 : 0))
                    Text("Setup log")
                }
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(logIsOpen ? "Hide setup log" : "Show setup log")
            .padding(.top, Metrics.gutter)

            if logIsOpen {
                CloudSetupLog(log: log, isFollowing: progress.isBuilding)
            }
        }
    }
}

/// One step: its mark on the rail, its label, what it is doing when it is the current one, and
/// how long it took where that is known.
struct CloudSetupStepRow: View {
    var step: CloudSetupProgress.Step
    var isLast: Bool
    var activity: String?
    var lastOutput: String?
    var duration: TimeInterval?
    var startedAt: Date?

    static let markSize: CGFloat = 18
    static let labelIndent: CGFloat = markSize + Metrics.gutter

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            HStack(alignment: .center, spacing: Metrics.gutter) {
                mark
                    .frame(width: Self.markSize, height: Self.markSize)
                Text(step.label)
                    .font(step.state == .current ? Typo.bodyEmphasis : Typo.body)
                    .foregroundStyle(ink)
                Spacer(minLength: Metrics.gutter)
                time
            }
            if let activity {
                Text(activity)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .padding(.leading, Self.labelIndent)
            }
            if let lastOutput {
                Text(lastOutput)
                    .font(Typo.codeTiny)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, Self.labelIndent)
            }
        }
        .padding(.bottom, isLast ? 0 : Self.gap)
        // The rail is behind the row rather than beside it, so it is as tall as whatever the row
        // turns out to hold, a current step's two extra lines included, and it reaches down to
        // the next step's mark.
        .background(alignment: .topLeading) {
            if !isLast {
                Rectangle()
                    .fill(step.state == .done ? Palette.positive.opacity(0.5) : Palette.border)
                    .frame(width: 1.5)
                    .frame(maxHeight: .infinity)
                    .padding(.top, Self.markSize + Metrics.spacingSmall)
                    .padding(.bottom, Metrics.spacingSmall)
                    .offset(x: (Self.markSize - 1.5) / 2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityState)
    }

    /// The space between one step and the next, which the rail crosses.
    private static let gap: CGFloat = Metrics.gutter + Metrics.spacingWide

    @ViewBuilder
    private var mark: some View {
        switch step.state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .resizable()
                .symbolRenderingMode(.palette)
                .foregroundStyle(Palette.textInverted, Palette.positive)
        case .current:
            // The app's own mark for work going on, in a ring, rather than a spinner: it is what
            // a running turn wears, and it pulses on the render server rather than on the main
            // thread. See `PulsingDot`.
            Circle()
                .strokeBorder(Palette.running.opacity(0.35), lineWidth: 1.5)
                .overlay { PulsingDot(diameter: 8, tint: Palette.running) }
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .resizable()
                .symbolRenderingMode(.palette)
                .foregroundStyle(Palette.textInverted, Palette.negative)
        case .todo:
            // The current step's ring, empty, in the rail's own ink. It was an eight point circle
            // in the tertiary ink, which left the column of marks heavy at the top and thin at the
            // bottom, with the rail stopping five points short of each one.
            Circle()
                .strokeBorder(Palette.border, lineWidth: 1.5)
        }
    }

    /// A finished step's duration, or a live clock for the current one when its start was seen.
    @ViewBuilder
    private var time: some View {
        if step.state == .current, let startedAt {
            CloudSetupElapsed(since: startedAt)
                .help("Time on this step")
        } else if step.state == .done, let duration {
            Text(TurnDuration.wholeSeconds(Int(duration * 1000)))
                .font(Typo.caption)
                .monospacedDigit()
                .foregroundStyle(Palette.textTertiary)
        }
    }

    private var ink: Color {
        switch step.state {
        case .done: Palette.textSecondary
        case .current: Palette.textPrimary
        case .failed: Palette.negative
        case .todo: Palette.textTertiary
        }
    }

    private var accessibilityState: String {
        switch step.state {
        case .done: "Done"
        case .current: "In progress"
        case .failed: "Failed"
        case .todo: "Not started"
        }
    }
}

/// Time since a moment, ticking once a second.
struct CloudSetupElapsed: View {
    var since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(TurnDuration.wholeSeconds(Int(max(0, context.date.timeIntervalSince(since)) * 1000)))
                .font(Typo.caption)
                .monospacedDigit()
                .foregroundStyle(Palette.textTertiary)
        }
    }
}

/// The first message, waiting for the workspace: the reader's own words in a queued bubble, and
/// what will happen to them.
struct CloudSetupHeldPrompt: View {
    var text: String

    private static let dots = StrokeStyle(lineWidth: Metrics.outline * 2, dash: [3, 3])

    var body: some View {
        VStack(alignment: .trailing, spacing: Metrics.spacing) {
            Text(text)
                .font(Typo.body)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(5)
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, Metrics.spacingWide)
                .background {
                    RoundedRectangle(cornerRadius: UserTurnRowView.corner)
                        .strokeBorder(Palette.textTertiary, style: Self.dots)
                }
            Label("Sends when the workspace is ready", systemImage: "clock")
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, UserTurnRowView.inset)
    }
}

/// The setup log, opened: the end of it, in the script's own type, following new lines while the
/// build is going. Only the tail, because a `composer install` log is thousands of lines.
///
/// **As tall as its lines up to a ceiling, and a scroller from there.** It was a fixed 260 points,
/// which drew a log of three lines in a box mostly empty. The height is worked out by
/// `LogHeight` from what the scroller holds rather than from anything the view remembers, so the
/// copy the transcript measures offscreen and the copy it draws agree without being told.
struct CloudSetupLog: View {
    var log: String
    var isFollowing: Bool

    private static let lines = 400
    private static let ceiling: CGFloat = 260

    var body: some View {
        LogHeight(ceiling: Self.ceiling) {
            ScrollView {
                Text(LogTail.last(log, lines: Self.lines))
                    .font(Typo.codeSmall)
                    .foregroundStyle(Palette.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Metrics.inset)
            }
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(isFollowing ? .bottom : .top, for: .sizeChanges)
        }
        .background(Palette.surfaceSunken, in: .rect(cornerRadius: Metrics.corner))
    }
}

/// A scroller as tall as what it holds, and no taller than `ceiling`.
///
/// A `Layout` rather than `.frame(maxHeight:)`, because that frame takes whatever height it is
/// offered up to the cap, and inside a scrolling card it is offered no height at all. Asking the
/// scroller for its ideal height, which for a vertical `ScrollView` is its content's, and
/// clamping that is a question with one answer for every proposal, so a measurement and a
/// drawing cannot disagree about it.
private struct LogHeight: Layout {
    var ceiling: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let ideal = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, ceiling))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}

/// The card on its own in a pane, before there is a conversation to put it at the head of.
///
/// **Laid out exactly as the transcript lays out its first entry**: the same space under the tab
/// strip and the same centred reading column. That is what makes the moment the first chat
/// arrives a composer appearing under a card that has not moved, rather than one screen swapped
/// for another. Scrolls, because an opened log is taller than a short window.
struct SetupCardPane<Card: View>: View {
    @ViewBuilder var card: Card

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .frame(height: TranscriptLayout.topSpace)
                    .accessibilityHidden(true)
                card
            }
            .frame(maxWidth: TranscriptLayout.conversationMeasure, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Palette.surface)
    }
}
