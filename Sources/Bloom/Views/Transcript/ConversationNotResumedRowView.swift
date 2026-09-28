import SwiftUI
import BloomCore

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
