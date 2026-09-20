import SwiftUI

/// The line across the top of the composer while it is addressed to a person, and the chip where
/// the words start. Both from the owner's messaging mockup, and the words agreed with the web
/// client so the two windows say the same thing.
///
/// **What it says is who does not see it.** A message to a person is drawn in the room for
/// everybody who has the workspace open; the one it never reaches is Bloom, and that is what
/// somebody has to be sure of before they type. Who it IS for is the chip, beside the words.
///
/// **It is there over an empty box too**, because the audience is state rather than something read
/// out of what is typed: after one message to Seb everything goes to Seb until it is changed, and
/// this line and its button are how it is changed without typing.
struct ComposerAddressLine: View {
    var onWriteToBloom: () -> Void

    var body: some View {
        VStack(spacing: Metrics.spacingSmall) {
            HStack(spacing: Metrics.spacingWide) {
                Text("Nothing you send here reaches Bloom.")
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Metrics.spacingSmall)
                Button("Write to @bloom", action: onWriteToBloom)
                    .buttonStyle(.plain)
                    .underline()
                    .foregroundStyle(Palette.textSecondary)
                    .pointerStyle(.link)
                    .help("The next message goes to Bloom again. Typing @bloom does the same.")
            }
            .font(Typo.caption)
            // Edge to edge under the line, through the box's own inset, as the mockup draws it: the
            // line is a band of the box rather than a caption inside it.
            Rectangle()
                .fill(Palette.directFill.opacity(0.26))
                .frame(height: Metrics.hairline)
                .padding(.horizontal, -Metrics.gutter)
                .accessibilityHidden(true)
        }
    }
}

/// "To Seb", where the message starts: who it is for, in the colour the bubble will be.
struct ComposerAddressChip: View {
    var name: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingHair) {
            Text("To").opacity(0.68)
            Text(name).fontWeight(.semibold)
        }
        .font(Typo.caption)
        .foregroundStyle(Palette.directFill)
        .padding(.horizontal, Metrics.spacingSmall)
        .padding(.vertical, 1)
        .background(Palette.directFill.opacity(0.16), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("To \(name)")
    }
}
