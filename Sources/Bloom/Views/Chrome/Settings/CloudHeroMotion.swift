import AppKit
import BloomCore
import QuartzCore
import SwiftUI

/// The moving half of the Bloom Cloud hero: Bloom's own app icon, taken apart into its layers,
/// stacked in depth and turned slowly under a travelling light. What moves and how is
/// `CloudHeroMotionPlan`, in the core; what the layers are is `BloomIconArtwork`.
///
/// **Real depth, not a picture that wobbles.** The five silhouettes sit at different z inside a
/// container whose `sublayerTransform` carries the perspective (`m34`), so a turn of a few degrees
/// moves the mark further than the ground beneath it, and the parallax is the projection's rather
/// than something drawn by hand. A specular band travels across the face, brightest as the face
/// turns towards it; the contact shadow leans the other way and softens as the icon leans; and the
/// water's glow behind slides with the same light.
///
/// **Core Animation, not SwiftUI.** The plan is sampled once into keyframe animations the render
/// server runs, so the window's process draws nothing per frame. **Paused while the window cannot
/// be seen**, from its occlusion state, and **still under Reduce Motion**, at the pose the plan
/// gives at zero.
///
/// The gallery renders this same layer tree through `CARenderer` at chosen moments, which is how
/// the frames sent for review are the motion that ships rather than a drawing of it.
struct CloudHeroMotion: NSViewRepresentable {
    /// Where the icon's centre sits, from the hero's leading edge.
    var markCentreX: CGFloat
    var markSize: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> CloudHeroMotionView {
        CloudHeroMotionView(markCentreX: markCentreX, markSize: markSize)
    }

    func updateNSView(_ view: CloudHeroMotionView, context: Context) {
        view.setMoving(!reduceMotion)
    }
}

final class CloudHeroMotionView: NSView {
    private let stack: CloudHeroIconStack
    private var moving = false
    private var laidOut: CGRect = .null
    private var occlusion: (any NSObjectProtocol)?

    init(markCentreX: CGFloat, markSize: CGFloat, frame: NSRect = .zero) {
        stack = CloudHeroIconStack(markCentreX: markCentreX, markSize: markSize)
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(stack.root)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        // Laid out again only when the size changed, so a layout pass for any other reason does
        // not restart the loops from zero.
        guard bounds != laidOut else { return }
        laidOut = bounds
        stack.place(in: bounds)
        if moving { stack.startAnimations() }
    }

    func setMoving(_ moving: Bool) {
        guard moving != self.moving else { return }
        self.moving = moving
        if moving { stack.startAnimations() } else { stack.stopAnimations() }
    }

    // MARK: - Visible or not

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = nil
        guard let window else { return }
        occlusion = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.followOcclusion() }
        }
        followOcclusion()
    }

    /// Stops the clock while the window is hidden and starts it again where it left off, the
    /// standard Core Animation pause, so nothing is spent on a Settings window behind another.
    private func followOcclusion() {
        guard let layer else { return }
        let visible = window?.occlusionState.contains(.visible) ?? false
        if visible, layer.speed == 0 {
            let paused = layer.timeOffset
            layer.speed = 1
            layer.timeOffset = 0
            layer.beginTime = 0
            layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - paused
        } else if !visible, layer.speed != 0 {
            let now = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.speed = 0
            layer.timeOffset = now
        }
    }
}

/// The layer tree itself, kept apart from the view so the gallery can render it with no view and
/// no window at all. See `CloudHeroFrames`.
@MainActor
final class CloudHeroIconStack {
    let root = CALayer()
    private let glow = CAGradientLayer()
    private let shadow = CALayer()
    private let scene = CALayer()
    private let sheen = CAGradientLayer()
    private let sheenHost = CALayer()
    private var faces: [CALayer] = []
    private let markCentreX: CGFloat
    private let markSize: CGFloat
    private var centre: CGPoint = .zero

    /// How far the eye is from the plane, in points. Shallow enough that a nine degree turn reads
    /// as a turn, deep enough that nothing shears.
    private static let eye: CGFloat = 900

    /// Where each of the icon's layers stands, in points off the ground. The gaps are what the
    /// parallax is made of, and they are small on purpose: at thirteen points the mark swung a
    /// clear two points clear of the ground's rounded corner at full turn, and an icon whose face
    /// hangs over its own edge reads as broken rather than as deep. At six it stays inside its
    /// outline and the layers still visibly slide against each other.
    private static let depths: [BloomIconArtwork.Layer: CGFloat] = [
        .mark: 6, .current: 4, .spatie: 4, .panel: 2, .ground: 0,
    ]

    init(markCentreX: CGFloat, markSize: CGFloat) {
        self.markCentreX = markCentreX
        self.markSize = markSize

        // The water's own light, behind everything, which slides with the icon's.
        glow.type = .radial
        glow.colors = [
            NSColor(rgb: 0x9BE9DC).withAlphaComponent(0.4).cgColor,
            NSColor(rgb: 0x9BE9DC).withAlphaComponent(0).cgColor,
        ]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        root.addSublayer(glow)

        // The contact shadow is the blur alone: a layer with a black background drew a hard slab
        // with a soft edge, which is a sticker's shadow rather than an object's.
        shadow.backgroundColor = NSColor.clear.cgColor
        shadow.shadowColor = NSColor.black.cgColor
        shadow.shadowOpacity = 1
        shadow.opacity = 0.45
        root.addSublayer(shadow)

        // The container the perspective lives in: every face is a child, so one transform turns
        // the whole object and each face's own z decides how far it swings.
        root.addSublayer(scene)

        for layer in [BloomIconArtwork.Layer.ground, .panel, .spatie, .current, .mark] {
            let face = CALayer()
            face.contentsGravity = .resizeAspect
            // Every face is clipped to the icon's shape, not just the ground. Icon Composer clips
            // the whole composition, which is why `ground.svg` is a plain square and why the mark's
            // ribbon runs past the edges of its own art: unclipped, it hung over the side.
            face.cornerRadius = markSize * 0.2237
            face.masksToBounds = true
            face.zPosition = Self.depths[layer] ?? 0
            face.contents = BloomIconArtwork.image(layer, size: markSize)
            if layer == .panel || layer == .mark {
                // The two groups `icon.json` gives a shadow to, which is what separates the glass
                // from the ground and the mark from the glass.
                face.shadowColor = NSColor.black.cgColor
                face.shadowOpacity = layer == .mark ? 0.5 : 0.55
                face.shadowRadius = layer == .mark ? 6 : 10
                face.shadowOffset = CGSize(width: 0, height: -3)
            }
            scene.addSublayer(face)
            faces.append(face)
        }

        // The travelling highlight, on the face of the object, clipped to the icon's own outline
        // so it cannot light the air beside it.
        sheen.colors = [
            NSColor.white.withAlphaComponent(0).cgColor,
            NSColor.white.withAlphaComponent(0.55).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
        ]
        sheen.startPoint = CGPoint(x: 0, y: 0)
        sheen.endPoint = CGPoint(x: 1, y: 1)
        sheen.opacity = 0
        sheenHost.masksToBounds = true
        sheenHost.zPosition = 20
        sheenHost.addSublayer(sheen)
        scene.addSublayer(sheenHost)
    }

    func place(in bounds: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = bounds
        centre = CGPoint(x: markCentreX, y: bounds.midY)

        glow.bounds = CGRect(x: 0, y: 0, width: markSize * 4, height: markSize * 4)
        glow.position = centre

        shadow.bounds = CGRect(x: 0, y: 0, width: markSize * 0.82, height: markSize * 0.42)
        shadow.cornerRadius = shadow.bounds.height / 2
        shadow.shadowPath = CGPath(
            roundedRect: shadow.bounds, cornerWidth: shadow.bounds.height / 2,
            cornerHeight: shadow.bounds.height / 2, transform: nil
        )
        shadow.position = CGPoint(x: centre.x, y: centre.y - markSize * 0.5)

        scene.frame = bounds
        // The perspective. Everything under `scene` is projected through this, so a face's own
        // `zPosition` is what decides how far it swings.
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / Self.eye
        scene.sublayerTransform = perspective

        for face in faces {
            face.bounds = CGRect(x: 0, y: 0, width: markSize, height: markSize)
            face.position = centre
            // **Depth magnified, then taken back out.** A face nearer the eye projects larger, so
            // the mark drawn at the icon's own size hung over the ground's rounded corners. Scaled
            // by the inverse of its own projection, every face reads the same size at rest and the
            // depth shows itself only in the parallax when the icon turns, which is the point.
            let scale = (Self.eye - face.zPosition) / Self.eye
            face.transform = CATransform3DMakeScale(scale, scale, 1)
        }
        sheenHost.bounds = CGRect(x: 0, y: 0, width: markSize, height: markSize)
        sheenHost.position = centre
        sheenHost.cornerRadius = markSize * 0.225
        sheen.bounds = CGRect(x: 0, y: 0, width: markSize * 0.38, height: markSize * 2)
        CATransaction.commit()
        apply(seconds: 0)
    }

    /// Every layer where the plan puts it `seconds` in, with no animation. For the resting pose
    /// under Reduce Motion.
    func apply(seconds: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let pose = CloudHeroMotionPlan.pose(atSeconds: seconds)
        scene.transform = Self.turn(pose)
        let cast = CloudHeroMotionPlan.shadow(for: pose)
        shadow.position = CGPoint(x: centre.x + cast.offsetX, y: centre.y - markSize * 0.5 + cast.offsetY)
        shadow.shadowRadius = cast.radius
        shadow.opacity = Float(cast.opacity)
        let slide = CloudHeroMotionPlan.glowOffset(for: pose)
        glow.position = CGPoint(x: centre.x + slide.x, y: centre.y + slide.y)
        sheen.position = CGPoint(x: markSize / 2 + markSize * 0.75 * pose.sheen, y: markSize / 2)
        sheen.opacity = Float(pose.sheenOpacity)
        CATransaction.commit()
    }

    /// The whole object's turn at a pose: yaw, pitch and a little roll, about its own centre.
    private static func turn(_ pose: CloudHeroMotionPlan.Pose) -> CATransform3D {
        var transform = CATransform3DMakeTranslation(0, 0, pose.lift)
        transform = CATransform3DRotate(transform, pose.yaw, 0, 1, 0)
        transform = CATransform3DRotate(transform, pose.pitch, 1, 0, 0)
        transform = CATransform3DRotate(transform, pose.roll, 0, 0, 1)
        return transform
    }

    // MARK: - The plan, as animations

    /// **One sampled loop per property, at the longest period.** A loop holding every track's
    /// period a whole number of times would be minutes long; this repeats the longest one, which
    /// is seamless because every track ends where it began, and the tracks inside it are at their
    /// own periods, so the composition still does not visibly repeat.
    func startAnimations() {
        stopAnimations()
        guard markSize > 0 else { return }
        let period = CloudHeroMotionPlan.periods.max() ?? 14
        let samples = 168

        func keyframes(_ keyPath: String, _ value: @escaping (CloudHeroMotionPlan.Pose) -> Any) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = (0...samples).map { step in
                value(CloudHeroMotionPlan.pose(atSeconds: Double(step) / Double(samples) * period))
            }
            animation.duration = period
            animation.repeatCount = .infinity
            animation.calculationMode = .linear
            return animation
        }

        let centre = centre
        let markSize = markSize
        scene.add(keyframes("transform") { NSValue(caTransform3D: Self.turn($0)) }, forKey: "turn")
        shadow.add(keyframes("position") { pose in
            let cast = CloudHeroMotionPlan.shadow(for: pose)
            return NSValue(point: CGPoint(x: centre.x + cast.offsetX, y: centre.y - markSize * 0.5 + cast.offsetY))
        }, forKey: "position")
        shadow.add(keyframes("shadowRadius") { CloudHeroMotionPlan.shadow(for: $0).radius }, forKey: "radius")
        shadow.add(keyframes("opacity") { Float(CloudHeroMotionPlan.shadow(for: $0).opacity) }, forKey: "opacity")
        glow.add(keyframes("position") { pose in
            let slide = CloudHeroMotionPlan.glowOffset(for: pose)
            return NSValue(point: CGPoint(x: centre.x + slide.x, y: centre.y + slide.y))
        }, forKey: "position")
        sheen.add(keyframes("position.x") { markSize / 2 + markSize * 0.75 * $0.sheen }, forKey: "position")
        sheen.add(keyframes("opacity") { Float($0.sheenOpacity) }, forKey: "opacity")
    }

    func stopAnimations() {
        for layer in [scene, shadow, glow, sheen] { layer.removeAllAnimations() }
        apply(seconds: 0)
    }
}
