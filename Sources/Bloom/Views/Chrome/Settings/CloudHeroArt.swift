import AppKit
import BloomClient
import SwiftUI

/// The plate at the head of Settings' Bloom Cloud pane: the app's own icon on the brand's water,
/// with the name beside it in the display serif. **Still, with no drift at all.**
///
/// It moved once, twice over: orbiting marks round the mark, then the icon turning in perspective
/// under a travelling light. The owner's verdict was "very cheap" on the first and "not what I'm
/// looking for, maybe something static but beautiful" on the second, so the motion was removed
/// rather than tuned, along with its plan, its tests and the renderer that photographed it. What is
/// left is meant to be looked at the way an About window is looked at: a real icon at a generous
/// size, a considered ground, one shadow that behaves like a shadow, and type with room around it.
///
/// **This composition was chosen from three.** The other two put the name under a larger centred
/// icon on a much taller plate, and cropped a very large icon against the plate's own corner. They
/// were drawn, photographed in both appearances and chosen between; the two that lost are gone
/// rather than kept behind a flag, and the pictures are in the message that carried the choice.
///
/// **Drawn in SwiftUI, with nothing that needs a window.** The icon is `BloomIconArtwork.composite`,
/// the icon's own layers filled from `icon.json` rather than the running copy's compiled icon, so a
/// dev or a Bloom Cloud build still shows Bloom's blue. What it should look like is not a matter of
/// opinion: `Tools/icon-truth.sh` renders the icon the way macOS does, and the fills here are held
/// against it. The water is `CloudSettingsWaterStill`, the live water's two pools at rest.
struct CloudHeroArt: View {
    var environment: RunbloomEnvironment?

    private static let corner: CGFloat = 12
    private static let height: CGFloat = 156
    private static let iconSize: CGFloat = 76
    private static let inset: CGFloat = 28

    var body: some View {
        ZStack {
            ground
            HStack(spacing: Self.inset) {
                icon
                words
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Self.inset)
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Bloom Cloud. Your agents, on machines of their own.")
    }

    /// Depth, the brand's plinth, with the water held still on it and a light behind where the icon
    /// stands, so the icon sits in the picture rather than on top of it. The hairline along the top
    /// edge is what keeps a dark plate from reading as a hole in a light pane.
    private var ground: some View {
        ZStack {
            Brand.depth
            CloudSettingsWaterStill()
            RadialGradient(
                colors: [Brand.shallow.opacity(0.28), .clear],
                center: UnitPoint(x: 0.13, y: 0.5), startRadius: 0, endRadius: Self.iconSize * 2.6
            )
        }
        .overlay(alignment: .top) {
            LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 1.5)
        }
    }

    private var icon: some View {
        Image(nsImage: BloomIconArtwork.composite(size: Self.iconSize) ?? Brand.mark)
            .resizable()
            .frame(width: Self.iconSize, height: Self.iconSize)
            // One shadow, close and soft, the way a thing resting on a surface casts one. Two
            // shadows at different radii is the mistake that makes an icon look pasted on.
            .shadow(color: .black.opacity(0.45), radius: Self.iconSize * 0.18, y: Self.iconSize * 0.09)
            .accessibilityHidden(true)
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "Bloom Cloud")
                .font(Typo.display)
                .tracking(Typo.displayTracking)
                .foregroundStyle(Brand.foam)
            Text("Your agents, on machines of their own.")
                .font(Typo.body)
                .foregroundStyle(Brand.mistDim)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
