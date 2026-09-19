import AppKit
import CoreGraphics

/// Bloom's app icon as separate layers, in its canonical blue, for anything that wants to light it
/// or move it rather than stamp it.
///
/// **The icon's own artwork, not a picture of it.** `Resources/Bloom.icon` is an Icon Composer
/// document: five silhouettes under `Assets/`, each filled with a gradient named in `icon.json`,
/// stacked in four groups. `Tools/build.sh` copies the silhouettes into the bundle and the
/// gradients are repeated here, which is the one duplication in this file and the reason for it:
/// **a dev build and a Bloom Cloud build tint `icon.json` so their Dock icons can be told apart**,
/// and the compiled `Assets.car` in those bundles is that tinted icon. The hero has to be Bloom's
/// blue in every build, so it is filled from these values rather than from whatever the running
/// copy's icon happens to be. Change the icon's colours and this file has to be changed with it;
/// nothing else here reads `icon.json` at runtime, because a dev build's copy is the wrong one.
///
/// The layers are handed out separately so `CloudHeroMotionView` can put them at different depths
/// and let perspective do the rest.
enum BloomIconArtwork {
    /// Front to back, which is the order `icon.json` lists its groups in.
    enum Layer: String, CaseIterable {
        case mark
        case current
        case spatie
        case panel
        case ground

        /// The gradient `icon.json` fills this silhouette with: top colour, bottom colour, and the
        /// unit y the gradient runs between.
        var fill: (top: NSColor, bottom: NSColor, start: CGFloat, stop: CGFloat) {
            switch self {
            case .mark:
                (NSColor(srgb: 0.6627, 0.9255, 0.8824), NSColor(srgb: 0.5412, 0.8118, 0.7686), 0.4055, 0.7023)
            case .current:
                (NSColor(srgb: 0.2824, 0.6902, 0.7451), NSColor(srgb: 0.1451, 0.5686, 0.6275), 0.7074, 0.8535)
            case .spatie:
                (NSColor(srgb: 0.2235, 0.5333, 0.6353), NSColor(srgb: 0.0863, 0.4078, 0.5137), 0.1465, 0.5633)
            case .panel:
                (NSColor(srgb: 0.1765, 0.2627, 0.3294), NSColor(srgb: 0.0392, 0.1255, 0.1961), 0.1465, 0.8535)
            case .ground:
                (NSColor(srgb: 0.9255, 0.9725, 0.9647), NSColor(srgb: 0.8118, 0.8627, 0.8510), 0, 1)
            }
        }
    }

    /// One layer, filled, at `size` points and `scale` pixels to the point.
    ///
    /// **The shape first, then the gradient through it with `.sourceIn`.** The obvious route,
    /// `clip(to:mask:)`, paints where the mask is light, so a silhouette drawn black on white
    /// clipped nothing and every layer came out as a filled square. Drawing the silhouette into a
    /// transparent context and compositing the gradient into what it covers needs no rule about
    /// which end of the grey scale means paint.
    ///
    /// Nil where the bundle has no such file, which is `swift run` and nothing else. The hero asks
    /// `hasLayers` first and falls back to the flat mark, so a missing file costs the depth rather
    /// than the picture.
    @MainActor
    static func image(_ layer: Layer, size: CGFloat, scale: CGFloat = 2) -> CGImage? {
        guard let url = url(for: layer), let art = NSImage(contentsOf: url) else { return nil }
        let pixels = Int(size * scale)
        guard pixels > 0, let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let box = CGRect(x: 0, y: 0, width: CGFloat(pixels), height: CGFloat(pixels))

        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        art.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        let fill = layer.fill
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [fill.top.cgColor, fill.bottom.cgColor] as CFArray, locations: [0, 1]
        ) else { return nil }
        context.setBlendMode(.sourceIn)
        // Unit y in `icon.json` runs from the top down; the context's runs from the bottom up.
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: box.midX, y: box.height * (1 - fill.start)),
            end: CGPoint(x: box.midX, y: box.height * (1 - fill.stop)),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        return context.makeImage()
    }

    /// Where a layer's silhouette is, in an app bundle or in a probe's.
    ///
    /// Two places, because two things assemble a bundle here: `Tools/build.sh` copies these five
    /// files flat into `Contents/Resources`, and `Tools/review-run-probe.sh` dittos the whole
    /// `Resources` folder, which keeps them under `Bloom.icon/Assets`. `Bundle.url(forResource:)`
    /// does not look inside subdirectories, so the probe found nothing and drew a hero with no
    /// icon in it at all.
    static func url(for layer: Layer) -> URL? {
        Bundle.main.url(forResource: layer.rawValue, withExtension: "svg")
            ?? Bundle.main.url(forResource: layer.rawValue, withExtension: "svg", subdirectory: "Bloom.icon/Assets")
    }

    /// Whether the bundle carries the layers at all. The hero asks before building its stack.
    static var hasLayers: Bool { url(for: .ground) != nil }
}

extension NSColor {
    fileprivate convenience init(srgb red: CGFloat, _ green: CGFloat, _ blue: CGFloat) {
        self.init(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}
