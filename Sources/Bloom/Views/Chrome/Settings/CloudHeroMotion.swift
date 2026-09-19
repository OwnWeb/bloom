import AppKit
import BloomCore
import QuartzCore
import SwiftUI

/// The moving half of the Bloom Cloud hero: the mark floating on a breathing halo, two machines
/// going round it on thin orbits, and a band of light crossing the plinth now and then. What moves
/// and how is `CloudHeroMotionPlan`, in the core.
///
/// **Core Animation, not SwiftUI.** The plan is sampled once into keyframe animations that the
/// render server runs, so the window's process draws nothing per frame, which is the same reason
/// `BrandWater` is layers. **Paused while the window cannot be seen**, from its occlusion state,
/// and **still under Reduce Motion**, with every layer at its phase-zero place.
///
/// The gallery calls `apply(seconds:)` to put every layer where the plan says it is at a moment
/// and renders the layer tree, which is how the frames sent for review are the shipping motion.
struct CloudHeroMotion: NSViewRepresentable {
    /// Where the mark's centre sits, from the hero's leading edge.
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
    private let markCentreX: CGFloat
    private let markSize: CGFloat
    private let sweep = CAGradientLayer()
    private let halo = CAGradientLayer()
    private let rings: [CAShapeLayer]
    private let machines: [CALayer]
    private let mark = CALayer()
    private var moving = false
    private var laidOut: CGRect = .null
    private var occlusion: (any NSObjectProtocol)?

    init(markCentreX: CGFloat, markSize: CGFloat, frame: NSRect = .zero) {
        self.markCentreX = markCentreX
        self.markSize = markSize
        rings = CloudHeroMotionPlan.orbits.map { _ in CAShapeLayer() }
        machines = CloudHeroMotionPlan.orbits.map { _ in CALayer() }
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true

        // A soft diagonal of light, the same seventeen degree lean as the water's ribbon.
        sweep.colors = [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.12).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        sweep.startPoint = CGPoint(x: 0, y: 0.5)
        sweep.endPoint = CGPoint(x: 1, y: 0.5)
        sweep.setAffineTransform(CGAffineTransform(rotationAngle: -0.3))

        halo.type = .radial
        halo.colors = [NSColor(rgb: 0x9BE9DC).withAlphaComponent(0.55).cgColor, NSColor(rgb: 0x9BE9DC).withAlphaComponent(0).cgColor]
        halo.startPoint = CGPoint(x: 0.5, y: 0.5)
        halo.endPoint = CGPoint(x: 1, y: 1)

        for ring in rings {
            ring.fillColor = nil
            ring.strokeColor = NSColor(rgb: 0xE9F7F4).withAlphaComponent(0.14).cgColor
            ring.lineWidth = 1
        }
        for machine in machines {
            machine.backgroundColor = NSColor(rgb: 0x9BE9DC).cgColor
            machine.bounds = CGRect(x: 0, y: 0, width: 5, height: 5)
            machine.cornerRadius = 2.5
            machine.shadowColor = NSColor(rgb: 0x9BE9DC).cgColor
            machine.shadowOpacity = 0.9
            machine.shadowRadius = 4
            machine.shadowOffset = .zero
        }

        mark.contents = Brand.mark
        mark.contentsGravity = .resizeAspect
        mark.shadowColor = NSColor.black.cgColor
        mark.shadowOpacity = 0.55
        mark.shadowRadius = 12
        mark.shadowOffset = CGSize(width: 0, height: -7)

        layer?.addSublayer(sweep)
        layer?.addSublayer(halo)
        rings.forEach { layer?.addSublayer($0) }
        // The first machine behind the mark and the second in front, so the orbits read as
        // round it rather than painted beside it.
        layer?.addSublayer(machines[0])
        layer?.addSublayer(mark)
        machines.dropFirst().forEach { layer?.addSublayer($0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }

    private var centre: CGPoint { CGPoint(x: markCentreX, y: bounds.midY) }

    override func layout() {
        super.layout()
        // Laid out again only when the size changed, so a layout pass for any other reason does
        // not restart the loops from zero.
        guard bounds != laidOut else { return }
        laidOut = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let height = bounds.height
        sweep.bounds = CGRect(x: 0, y: 0, width: max(bounds.width * 0.35, 1), height: height * 2.2)
        sweep.position = CGPoint(x: bounds.width * CloudHeroMotionPlan.sweep.value(0), y: bounds.midY)
        halo.bounds = CGRect(x: 0, y: 0, width: markSize * 1.9, height: markSize * 1.9)
        halo.position = centre
        for (ring, orbit) in zip(rings, CloudHeroMotionPlan.orbits) {
            ring.frame = bounds
            ring.path = Self.path(of: orbit, round: centre)
        }
        mark.bounds = CGRect(x: 0, y: 0, width: markSize, height: markSize)
        mark.position = centre
        CATransaction.commit()
        apply(seconds: 0)
        if moving { startAnimations() }
    }

    func setMoving(_ moving: Bool) {
        guard moving != self.moving else { return }
        self.moving = moving
        if moving { startAnimations() } else { stopAnimations() }
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

    // MARK: - The plan, as animations or as one moment

    /// Every layer where the plan puts it `seconds` in, with no animation. For a still frame.
    func apply(seconds: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sweep.position.x = bounds.width * CloudHeroMotionPlan.sweep.at(seconds: seconds)
        halo.opacity = Float(CloudHeroMotionPlan.haloOpacity.at(seconds: seconds))
        let scale = CloudHeroMotionPlan.haloScale.at(seconds: seconds)
        halo.transform = CATransform3DMakeScale(scale, scale, 1)
        for (machine, orbit) in zip(machines, CloudHeroMotionPlan.orbits) {
            let offset = orbit.position(atSeconds: seconds)
            machine.position = CGPoint(x: centre.x + offset.x, y: centre.y + offset.y)
        }
        mark.position = CGPoint(x: centre.x, y: centre.y + CloudHeroMotionPlan.float.at(seconds: seconds))
        CATransaction.commit()
    }

    private func startAnimations() {
        stopAnimations()
        guard bounds.width > 0 else { return }
        sweep.add(Self.keyframes("position.x", CloudHeroMotionPlan.sweep) { self.bounds.width * $0 }, forKey: "motion")
        halo.add(Self.keyframes("opacity", CloudHeroMotionPlan.haloOpacity) { $0 }, forKey: "opacity")
        halo.add(Self.keyframes("transform.scale", CloudHeroMotionPlan.haloScale) { $0 }, forKey: "scale")
        mark.add(Self.keyframes("position.y", CloudHeroMotionPlan.float) { self.centre.y + $0 }, forKey: "motion")
        for (machine, orbit) in zip(machines, CloudHeroMotionPlan.orbits) {
            let animation = CAKeyframeAnimation(keyPath: "position")
            let samples = 96
            animation.values = (0...samples).map { step in
                let offset = orbit.position(phase: (Double(step) / Double(samples) + orbit.start).truncatingRemainder(dividingBy: 1))
                return NSValue(point: CGPoint(x: centre.x + offset.x, y: centre.y + offset.y))
            }
            animation.duration = orbit.period
            animation.repeatCount = .infinity
            machine.add(animation, forKey: "motion")
        }
    }

    private func stopAnimations() {
        [sweep, halo, mark].forEach { $0.removeAllAnimations() }
        machines.forEach { $0.removeAllAnimations() }
        apply(seconds: 0)
    }

    /// A track sampled into a looping keyframe animation. Linear between samples, which at
    /// sixty-odd a loop is indistinguishable from the curve.
    private static func keyframes(_ keyPath: String, _ track: CloudHeroMotionPlan.Track, _ map: (Double) -> Double) -> CAKeyframeAnimation {
        let samples = 72
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = (0...samples).map { map(track.value(Double($0) / Double(samples))) }
        animation.duration = track.period
        animation.repeatCount = .infinity
        return animation
    }

    private static func path(of orbit: CloudHeroMotionPlan.Orbit, round centre: CGPoint) -> CGPath {
        let path = CGMutablePath()
        let steps = 120
        for step in 0...steps {
            let offset = orbit.position(phase: Double(step) / Double(steps))
            let point = CGPoint(x: centre.x + offset.x, y: centre.y + offset.y)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    /// The layers at `seconds`, rendered to an image. For the gallery, which cannot draw a live
    /// NSView through `ImageRenderer`.
    @MainActor
    static func still(size: CGSize, markCentreX: CGFloat, markSize: CGFloat, seconds: Double, scale: CGFloat = 2) -> NSImage? {
        let view = CloudHeroMotionView(markCentreX: markCentreX, markSize: markSize, frame: CGRect(origin: .zero, size: size))
        view.layout()
        view.apply(seconds: seconds)
        guard let layer = view.layer,
              let context = CGContext(
                  data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: size)
    }
}
