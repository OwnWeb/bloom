import AppKit
import CoreGraphics
import Metal
import QuartzCore

/// Frames of the Bloom Cloud hero's motion, rendered with no window and nothing on screen.
///
/// **`CARenderer`, because the motion is real 3D.** `CALayer.render(in:)` draws a layer tree
/// through a `CGContext`, which flattens it: a `sublayerTransform` carrying `m34` is not a 2D
/// transform, so the perspective, and with it the whole point of the hero, disappears from the
/// picture. `CARenderer` is Core Animation's own offscreen compositor, it takes a Metal texture,
/// and `beginFrame(atTime:timeStamp:)` drives the running animations to whatever moment is asked for. So the
/// frames sent for review are the shipping layer tree, with its shipping animations, at a time of
/// our choosing, and no window is ever put in front of anybody.
///
/// A texture per frame rather than one reused: `CARenderer` composites its updates onto whatever
/// the texture holds, and a fresh one is the cheapest way to be sure a frame is not the last frame
/// with this one drawn over it.
@MainActor
enum CloudHeroFrames {
    /// The motion alone, transparent apart from the icon, its shadow and its glow.
    static func image(size: CGSize, markCentreX: CGFloat, markSize: CGFloat, seconds: Double, scale: CGFloat = 2) -> NSImage? {
        guard let cgImage = render(size: size, markCentreX: markCentreX, markSize: markSize, seconds: seconds, scale: scale) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: size)
    }

    /// A plain red layer through the same path, so a probe can tell "this machine's CARenderer
    /// drew nothing" from "the hero's layer tree drew nothing".
    static func selfTestImage() -> CGImage? {
        let layer = CALayer()
        layer.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        layer.backgroundColor = NSColor.red.cgColor
        return render(layer, pixels: CGSize(width: 64, height: 64), seconds: 0)
    }

    static func render(size: CGSize, markCentreX: CGFloat, markSize: CGFloat, seconds: Double, scale: CGFloat = 2, drawsGlow: Bool = true) -> CGImage? {
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        guard width > 0, height > 0 else { return nil }

        let stack = CloudHeroIconStack(markCentreX: markCentreX * scale, markSize: markSize * scale, drawsGlow: drawsGlow)
        stack.place(in: CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        stack.startAnimations()
        return render(stack.root, pixels: CGSize(width: CGFloat(width), height: CGFloat(height)), seconds: seconds, scale: scale)
    }

    /// One layer tree, at one moment, into an image.
    static func render(_ root: CALayer, pixels: CGSize, seconds: Double, scale: CGFloat = 1) -> CGImage? {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        let width = Int(pixels.width)
        let height = Int(pixels.height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        root.contentsScale = scale
        root.layoutIfNeeded()
        root.displayIfNeeded()

        // **Our own queue, which is the difference between a picture and an empty file.**
        // CARenderer encodes onto a queue of its own unless it is given one, and a read on this
        // side is then racing work we cannot wait for: the same frame came out drawn, then empty,
        // then drawn. Sharing the queue puts our wait after its work.
        let renderer = CARenderer(mtlTexture: texture, options: [
            kCARendererColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            kCARendererMetalCommandQueue: queue,
        ])
        renderer.layer = root
        renderer.bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        // The animations were added at time zero of this tree's own clock, so asking for `seconds`
        // is asking for the pose the running hero is in `seconds` after it started.
        // Flushed before the first frame: CARenderer reads a committed tree, and a tree built in
        // this turn of the run loop has not been committed yet.
        CATransaction.flush()
        // **Asked for in the tree's own clock, which starts at the current media time.** An
        // animation added without a `beginTime` is stamped with the media time when it is
        // committed, so `beginFrame(atTime: 3)` is three seconds after the machine booted, long
        // before this tree existed: every frame came out identical, at the animation's first value.
        let origin = CACurrentMediaTime()
        for _ in 0..<2 {
            renderer.beginFrame(atTime: origin + seconds, timeStamp: nil)
            renderer.addUpdate(renderer.bounds)
            renderer.render()
            renderer.endFrame()
        }

        // The GPU's work has to be finished before the bytes are read.
        guard let commands = queue.makeCommandBuffer() else { return nil }
        commands.commit()
        commands.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            texture.getBytes(
                buffer.baseAddress!, bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0
            )
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        // Core Animation composites with y up and a CGImage's first row is its top, so what comes
        // out of the texture is upside down: the contact shadow sat above the icon until this.
        guard let raw = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ) else { return nil }
        guard let flipped = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        flipped.translateBy(x: 0, y: CGFloat(height))
        flipped.scaleBy(x: 1, y: -1)
        flipped.draw(raw, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        return flipped.makeImage()
    }
}
