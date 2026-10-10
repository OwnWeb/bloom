import SwiftUI
import BloomCore

/// The automatic router at work, over the top of the conversation it is choosing a model for.
///
/// A spinner while Claude Haiku reads the task, its thinking under the spinner as it is written,
/// and then the model and effort it settled on, until the first message goes. Every word and the
/// rule for whether the card is drawn at all are `ModelRouteCaption`'s, in the core.
///
/// An overlay rather than an entry in the transcript's table. The table measures and caches every
/// entry's height against a content key, and a block of text that grows several times a second
/// for ten seconds and then goes away for good is the one shape that arrangement is worst at.
/// Hung over the top of the pane it costs the table nothing, the way the pinned question does.
struct OpeningRouteCard: View {
    let route: OpeningRoute
    /// Read for one fact, whether the conversation has a row yet, and read here rather than in
    /// `ChatPaneView` so the rows arriving re-run this small body and never the pane's.
    let transcript: TranscriptModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isShown: Bool {
        ModelRouteCaption.showsCard(
            isSettled: route.isSettled,
            isDismissed: route.isDismissed,
            hasConversationStarted: !transcript.rows.isEmpty
        )
    }

    var body: some View {
        Group {
            if isShown {
                card.transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : Motion.hover, value: isShown)
        .animation(reduceMotion ? nil : Motion.hover, value: route.isSettled)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            HStack(spacing: Metrics.spacingWide) {
                if route.isSettled {
                    Image(systemName: route.route == nil ? "arrow.uturn.backward" : "checkmark.circle")
                        .font(Typo.label)
                        .foregroundStyle(Palette.textSecondary)
                        .accessibilityHidden(true)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }

                Text(ModelRouteCaption.title(route: route.route, isSettled: route.isSettled))
                    .font(Typo.labelEmphasis)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                if route.isSettled {
                    Button("Dismiss") { route.isDismissed = true }
                        .linkButton()
                        .font(Typo.caption)
                } else {
                    Button("Skip") { route.skip() }
                        .linkButton()
                        .font(Typo.caption)
                        .help("Start on the model and effort the new workspace window was set to")
                }
            }

            Text(ModelRouteCaption.detail(
                route: route.route, isSettled: route.isSettled, wasSkipped: route.wasSkipped
            ))
            .font(Typo.caption)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            // The model's own thinking, newest end, while there is still something to wait for.
            // Gone once the route has settled: the reason under the title says why in one line,
            // and a paragraph of working under a decision reads as the decision being unsure.
            if !route.isSettled {
                let reasoning = ModelRouteCaption.reasoningTail(route.progress.reasoning)
                if !reasoning.isEmpty {
                    Text(reasoning)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Claude Haiku is thinking: \(reasoning)")
                }
            }
        }
        .padding(Metrics.gutter)
        .frame(maxWidth: TranscriptLayout.conversationMeasure, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Metrics.corner * 2))
        .padding(.horizontal, ComposerLayout.horizontalInset)
        .padding(.top, Metrics.spacingWide)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
    }
}
