import AppKit
import BloomClient
import SwiftUI

/// The plate at the head of Settings' Bloom Cloud pane: the app's own icon on the brand's water,
/// with the name in the display serif. **Still.**
///
/// It moved once: the icon turned in perspective under a travelling light, with orbiting marks
/// before that. The owner's verdict on the first was "very cheap" and on the second "not what I'm
/// looking for, maybe something static but beautiful", so the motion is gone rather than tuned.
/// What is left is meant to be looked at the way an About window is looked at: a real icon at a
/// generous size, a considered ground, one shadow that behaves like a shadow, and type with room
/// around it.
///
/// **Three compositions, because the difference between them is a design question rather than a
/// number.** They differ in framing, in how much ground there is, in the icon's size and in
/// whether the name sits beside the icon or under it. `CloudSettingsGallery` photographs each in
/// both appearances so the owner can choose one; the chosen one is `CloudHeroArt.Composition`'s
/// default.
///
/// **Drawn in SwiftUI, with nothing that needs a window.** The icon is `BloomIconArtwork.composite`,
/// which is the icon's own layers filled from `icon.json` rather than the running copy's icon, so
/// a dev or Cloud build shows Bloom's blue. The water is `CloudSettingsWaterStill`, the live
/// water's two pools at rest.
struct CloudHeroArt: View {
    enum Composition: String, CaseIterable {
        /// The name beside the icon, on a band the height of the old hero.
        case beside
        /// The icon centred with the name under it, on a taller plate with air around both.
        case beneath
        /// A large icon cropped by the plate's own corner, with the name given the width.
        case plate

        /// What the owner chose.
        static let chosen = Composition.beside

        var height: CGFloat {
            switch self {
            case .beside: 156
            case .beneath: 232
            case .plate: 180
            }
        }

        var iconSize: CGFloat {
            switch self {
            case .beside: 76
            case .beneath: 92
            case .plate: 132
            }
        }
    }

    var composition: Composition = .chosen
    var environment: RunbloomEnvironment?

    private static let corner: CGFloat = 12
    private static let inset: CGFloat = 28

    var body: some View {
        ZStack {
            ground
            content
        }
        .frame(height: composition.height)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Bloom Cloud. Your agents, on machines of their own.")
    }

    // MARK: - The ground

    /// Depth, the brand's plinth, with the water held still on it and a light behind where the
    /// icon stands, so the icon sits in the picture rather than on top of it. The hairline along
    /// the top edge is what keeps a dark plate from reading as a hole in a light pane.
    private var ground: some View {
        ZStack {
            Brand.depth
            CloudSettingsWaterStill()
            RadialGradient(
                colors: [Brand.shallow.opacity(0.28), .clear],
                center: lightCentre, startRadius: 0, endRadius: composition.iconSize * 2.6
            )
        }
        .overlay(alignment: .top) {
            LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 1.5)
        }
    }

    private var lightCentre: UnitPoint {
        switch composition {
        case .beside: UnitPoint(x: 0.13, y: 0.5)
        case .beneath: UnitPoint(x: 0.5, y: 0.34)
        case .plate: UnitPoint(x: 0.82, y: 0.45)
        }
    }

    // MARK: - The compositions

    @ViewBuilder
    private var content: some View {
        switch composition {
        case .beside:
            HStack(spacing: Self.inset) {
                icon
                words(alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Self.inset)
        case .beneath:
            VStack(spacing: Metrics.gutter + Metrics.spacing) {
                icon
                words(alignment: .center)
            }
            .padding(.horizontal, Self.inset)
        case .plate:
            ZStack(alignment: .leading) {
                // Cropped by the plate's own corner, which is the one liberty here: an icon that
                // runs off the edge reads as a window onto something larger, where an icon with
                // air all round reads as a sticker on a card.
                HStack {
                    Spacer(minLength: 0)
                    icon.offset(x: composition.iconSize * 0.22)
                }
                words(alignment: .leading)
                    .padding(.trailing, composition.iconSize)
            }
            .padding(.horizontal, Self.inset)
        }
    }

    private var icon: some View {
        Image(nsImage: BloomIconArtwork.composite(size: composition.iconSize) ?? Brand.mark)
            .resizable()
            .frame(width: composition.iconSize, height: composition.iconSize)
            // One shadow, close and soft, the way a thing resting on a surface casts one. Two
            // shadows at different radii is the mistake that makes an icon look pasted.
            .shadow(color: .black.opacity(0.45), radius: composition.iconSize * 0.18, y: composition.iconSize * 0.09)
            .accessibilityHidden(true)
    }

    private func words(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 6) {
            Text(verbatim: "Bloom Cloud")
                .font(Typo.display)
                .tracking(Typo.displayTracking)
                .foregroundStyle(Brand.foam)
            Text("Your agents, on machines of their own.")
                .font(Typo.body)
                .foregroundStyle(Brand.mistDim)
        }
        .multilineTextAlignment(alignment == .center ? .center : .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
