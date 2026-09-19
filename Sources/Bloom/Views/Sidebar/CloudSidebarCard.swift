import AppKit
import BloomClient
import SwiftUI

/// Bloom Cloud in the sidebar while nobody is signed in: one small card, in place of the section.
///
/// **The Settings pane's hero, made small.** Depth with the water held still behind it, the mark,
/// the name in the display serif and one line in foam, so the card and the pane it opens
/// onto read as the same thing. No heading above it: the card carries the name, and printing it
/// twice is what the owner sent back. See `CloudSidebarPresence` for when it is shown.
///
/// **Drawn entirely in SwiftUI**, plain buttons included, so `CloudSidebarGallery` photographs the
/// real card offscreen. The water is the still one for the same reason: the live water is Core
/// Animation, and in a sidebar somebody looks at all day a breathing card would be a distraction.
struct CloudSidebarCard: View {
    var isSigningIn: Bool
    var signIn: () -> Void
    var cancelSignIn: () -> Void
    var dismiss: () -> Void
    /// Forces the dismiss button into view, for a photograph of the hovered card.
    var showsDismiss = false

    @State private var hovering = false

    private static let corner: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            HStack(spacing: Metrics.spacing) {
                // The app's own layered icon, in its canonical blue, never the running copy's
                // tinted one. The flat mark is the fallback for a bundle without the layers.
                Image(nsImage: BloomIconArtwork.composite(size: 24) ?? Brand.mark)
                    .resizable()
                    .frame(width: 24, height: 24)
                    .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
                    .accessibilityHidden(true)
                Text(verbatim: "Bloom Cloud")
                    .font(.system(.title3, design: .serif, weight: .regular))
                    .foregroundStyle(Brand.foam)
                    .accessibilityAddTraits(.isHeader)
            }
            // `lineLimit(nil)` as well as the fixed size: a `.sidebar` list row holds its text to one
            // line, which cut this to "Run agents on their own machine..." in the real list while
            // the card on its own showed both lines. It is what truncated the old block too.
            Text(CloudSidebarPresence.cardLine)
                .font(.callout)
                .foregroundStyle(Brand.foam.opacity(0.8))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            if isSigningIn {
                HStack(spacing: Metrics.spacing) {
                    Text("Finish in your browser.")
                        .font(.callout)
                        .foregroundStyle(Brand.mistDim)
                    Spacer(minLength: 0)
                    Button("Cancel", action: cancelSignIn)
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(Brand.shallow)
                }
                .padding(.top, Metrics.spacingSmall)
            } else {
                Button(action: signIn) {
                    Text("Sign In")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Brand.fathom)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Brand.shallow, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, Metrics.spacingSmall)
            }
        }
        .padding(Metrics.spacingWide + Metrics.spacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                Brand.depth
                CloudSettingsWaterStill()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if hovering || showsDismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Brand.foam.opacity(0.8))
                        .frame(width: 18, height: 18)
                        .background(Color.white.opacity(0.12), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(CloudSidebarPresence.dismissHelp)
                .accessibilityLabel("Hide Bloom Cloud")
                .padding(Metrics.spacing)
            }
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        // The button only appears under the pointer, so the same thing is offered without one.
        .accessibilityAction(named: "Hide Bloom Cloud", dismiss)
    }
}
