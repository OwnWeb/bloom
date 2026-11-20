import SwiftUI
import BloomCore

/// Words steered into an OpenCode turn that a Stop overtook. See `OpenCodeSteerNote`.
struct SteerUnreadRowView: View {
    var sentence: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: TranscriptLayout.glyphGap) {
            TranscriptGlyph(symbol: "clock.arrow.circlepath", tint: Palette.textTertiary)

            Text("Held")
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
                .transcriptLabelColumn("Held", font: Typo.label)

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
