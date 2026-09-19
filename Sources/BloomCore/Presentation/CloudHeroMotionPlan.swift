import Foundation

/// How the Bloom Cloud hero moves: the icon turning slowly in space under a light that travels
/// across it, with its shadow and the water behind it following.
///
/// **One description, read twice.** The live hero samples these functions into Core Animation
/// keyframes that the render server runs, and the gallery renders frames of that same layer tree
/// through `CARenderer` at chosen moments, so what is sent for review is the motion that ships.
///
/// **It is the icon's own layers, not a picture of it**: `BloomIconArtwork` hands out the five
/// silhouettes filled from `icon.json`, the view separates them in z, and the perspective in the
/// container does the parallax. Nothing here knows about layers; it is the movement alone.
///
/// **Rich but calm.** Every loop is between eight and fourteen seconds, every track ends where it
/// began so no loop point shows, the turn never exceeds nine degrees, and the sheen is a
/// travelling highlight rather than a flash. The periods share no small common factor, so the
/// composition does not visibly repeat: yaw and pitch alone are back together every 143 seconds.
public enum CloudHeroMotionPlan {
    public struct Track: Sendable {
        public let period: Double
        /// The value at a phase from 0 to 1. Equal at both ends.
        public let value: @Sendable (Double) -> Double

        public func at(seconds: Double) -> Double {
            value((seconds / period).truncatingRemainder(dividingBy: 1))
        }
    }

    /// Turning left and right, in radians: nine degrees each way on an eleven second breath.
    public static let yaw = Track(period: 11) { 0.157 * sin($0 * 2 * .pi) }

    /// Nodding, in radians: six degrees, on thirteen, so the two are never in step.
    public static let pitch = Track(period: 13) { 0.105 * sin($0 * 2 * .pi) }

    /// A slow rock in the plane of the screen, a degree and a half, which is what keeps the turn
    /// from reading as a hinge.
    public static let roll = Track(period: 9) { 0.026 * sin($0 * 2 * .pi) }

    /// The icon breathing towards the reader, in points of z.
    public static let lift = Track(period: 12) { 6 * sin($0 * 2 * .pi) }

    /// Where the light is across the icon, from -1 (off the leading edge) to 1 (off the trailing
    /// edge), on a fourteen second cycle: it crosses in the first two fifths and then rests off
    /// the edge, which is how a highlight on a real surface behaves as the light passes.
    public static let sheen = Track(period: 14) { phase in
        let crossing = 0.4
        guard phase < crossing else { return 1.25 }
        let t = phase / crossing
        return -1.25 + 2.5 * (t * t * (3 - 2 * t))
    }

    /// How strong the sheen is, so it fades in and out rather than appearing at the edge.
    public static let sheenOpacity = Track(period: 14) { phase in
        let crossing = 0.4
        guard phase < crossing else { return 0 }
        return 0.5 * sin((phase / crossing) * .pi)
    }

    /// How much of the light the whole icon catches, which rises as it turns towards the source.
    public static let sheenTilt = Track(period: 11) { 0.5 + 0.5 * sin($0 * 2 * .pi) }

    /// Every loop, for the tests and for anything that has to pause them all.
    public static var periods: [Double] {
        [yaw, pitch, roll, lift, sheen, sheenOpacity, sheenTilt].map(\.period)
    }

    /// The whole plan at one moment, which is what a still frame sets and what the live view
    /// samples into keyframes.
    public struct Pose: Sendable, Equatable {
        public var yaw: Double
        public var pitch: Double
        public var roll: Double
        public var lift: Double
        public var sheen: Double
        public var sheenOpacity: Double
    }

    public static func pose(atSeconds seconds: Double) -> Pose {
        Pose(
            yaw: yaw.at(seconds: seconds),
            pitch: pitch.at(seconds: seconds),
            roll: roll.at(seconds: seconds),
            lift: lift.at(seconds: seconds),
            sheen: sheen.at(seconds: seconds),
            // The travelling highlight, dimmed by how far the face is turned away from the light.
            sheenOpacity: sheenOpacity.at(seconds: seconds) * (0.55 + 0.45 * sheenTilt.at(seconds: seconds))
        )
    }

    /// Where the icon's shadow falls and how soft it is, from the pose: a shadow moves opposite to
    /// the face that lifts, and spreads as the object leans away from its ground.
    public static func shadow(for pose: Pose) -> (offsetX: Double, offsetY: Double, radius: Double, opacity: Double) {
        let offsetX = -pose.yaw * 90
        let offsetY = -14 - pose.pitch * 60 - pose.lift
        let lean = (abs(pose.yaw) + abs(pose.pitch)) / 0.262
        return (offsetX, offsetY, 16 + 10 * lean, 0.45 - 0.1 * lean)
    }

    /// Where the water's glow sits behind the icon, in points, so the light in the plinth and the
    /// light on the icon are the same light.
    public static func glowOffset(for pose: Pose) -> (x: Double, y: Double) {
        (pose.yaw * 120, pose.pitch * 70)
    }
}
