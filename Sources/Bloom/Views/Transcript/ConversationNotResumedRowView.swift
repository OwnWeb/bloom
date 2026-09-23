import SwiftUI
import BloomCore

/// The note left where a chat's conversation could not be resumed and a new one began.
///
/// Quiet, in the rate limit row's register rather than the error row's, because nothing failed
/// that anybody has to act on: on a Cloud machine the same turn has already been sent again. It
/// is there so that an agent that no longer remembers what was said above is not a mystery. What
/// it says, and which `.notice` rows are this one, is `ConversationNotResumed`, in the core.
struct ConversationNotResumedRowView: View {
    var sentence: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: TranscriptLayout.glyphGap) {
            TranscriptGlyph(symbol: "arrow.counterclockwise", tint: Palette.textTertiary)

            Text("New conversation")
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
                .transcriptLabelColumn("New conversation", font: Typo.label)

            Text(sentence)
                .font(Typo.label)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .transcriptRowFrame()
        .accessibilityElement(children: .combine)
    }
}
