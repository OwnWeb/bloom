import SwiftUI
import BloomCore

/// The automatic router at work, at the head of the conversation it is choosing a model for.
/// Every word and the rule for drawing it are `ModelRouteCaption`'s.
///
/// Above the transcript rather than in its table, which caches row heights and handles a block
/// that grows several times a second worst of all.
struct OpeningRouteCard: View {
    let route: OpeningRoute
    /// Read here rather than in `ChatPaneView` so arriving rows re-run this small body, not the pane's.
    let transcript: TranscriptModel
    /// The workspace lets go of the route, so nothing watches the rows for the rest of its life.
    var onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isShown: Bool {
        ModelRouteCaption.showsCard(
            isSettled: route.isSettled,
            isDismissed: route.isDismissed,
            hasSessionStarted: transcript.rows.contains {
                TranscriptRowInk.isSessionStart(kind: $0.kind, payload: $0.payload)
            }
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
        .onChange(of: isShown) { _, shown in
            if !shown { onFinished() }
        }
    }

    /// Drawn as a transcript row, because a glass card above the conversation read as a box inside
    /// a box.
    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: TranscriptLayout.glyphGap) {
                statusGlyph
                    .frame(width: TranscriptLayout.glyphWidth)

                Text(ModelRouteCaption.title(route: route.route, isSettled: route.isSettled))
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
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
            .transcriptRowFrame()

            detailText(ModelRouteCaption.detail(
                route: route.route, isSettled: route.isSettled, wasSkipped: route.wasSkipped,
                analyser: route.analyser.name,
                readsOnlyTheMessage: route.analyser.kind == .claudeCode
            ))

            // Gone once settled: a paragraph of working under a decision reads as the decision being unsure.
            if !route.isSettled {
                let reasoning = ModelRouteCaption.reasoningTail(route.progress.reasoning)
                if !reasoning.isEmpty {
                    detailText(reasoning)
                        .lineLimit(4)
                        .padding(.top, Metrics.spacingSmall)
                        .accessibilityLabel("\(route.analyser.name) is thinking: \(reasoning)")
                }
            }
        }
        .padding(.horizontal, TranscriptLayout.inset)
        .padding(.vertical, TranscriptLayout.block)
        .frame(maxWidth: TranscriptLayout.conversationMeasure, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var statusGlyph: some View {
        if route.isSettled {
            TranscriptGlyph(symbol: route.route == nil ? "arrow.uturn.backward" : "checkmark.circle")
        } else {
            ProgressView()
                .controlSize(.mini)
                .accessibilityHidden(true)
        }
    }

    /// Under the title, where an expanded row's body goes.
    private func detailText(_ text: String) -> some View {
        Text(text)
            .font(Typo.caption)
            .foregroundStyle(Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, TranscriptLayout.detailIndent)
            .padding(.trailing, TranscriptLayout.inset)
    }
}
