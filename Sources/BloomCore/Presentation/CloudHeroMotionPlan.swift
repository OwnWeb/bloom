import Foundation

/// How the Bloom Cloud hero moves: the mark floating, a halo breathing behind it, two machines on
/// thin orbits round it, and a band of light crossing the plinth now and then.
///
/// **One description, read twice.** The live hero samples these functions into Core Animation
/// keyframes, and the gallery sets each layer to the same functions at a chosen moment to render
/// frames offscreen, so the frames shown for review are the motion that ships rather than a
/// separate drawing of it.
///
/// **Calm by construction.** Every loop is between six and twelve seconds, every track ends where
/// it began so no loop point shows, nothing flashes (the brightest the halo gets is a little over
/// half), and the band of light crosses in four seconds and then leaves the plinth alone for seven.
/// The periods share no common factor below their product, so the whole never visibly repeats.
public enum CloudHeroMotionPlan {
    public struct Track: Sendable {
        public let period: Double
        /// The value at a phase from 0 to 1. Equal at both ends.
        public let value: @Sendable (Double) -> Double

        public func at(seconds: Double) -> Double {
            value((seconds / period).truncatingRemainder(dividingBy: 1))
        }
    }

    /// An orbit: an ellipse round the mark's centre, tilted, and how long one machine takes to go
    /// round it once. Sizes are in points.
    public struct Orbit: Sendable {
        public let radiusX: Double
        public let radiusY: Double
        /// Clockwise tilt, in radians.
        public let tilt: Double
        public let period: Double
        /// Where on the orbit the machine starts, from 0 to 1, so the two are not in step.
        public let start: Double

        /// The machine's offset from the mark's centre at `seconds`, with y up.
        public func position(atSeconds seconds: Double) -> (x: Double, y: Double) {
            position(phase: (seconds / period + start).truncatingRemainder(dividingBy: 1))
        }

        public func position(phase: Double) -> (x: Double, y: Double) {
            let angle = phase * 2 * .pi
            let x = radiusX * cos(angle)
            let y = radiusY * sin(angle)
            return (x * cos(tilt) - y * sin(tilt), x * sin(tilt) + y * cos(tilt))
        }
    }

    /// Up and down by three points on a nine second breath.
    public static let float = Track(period: 9) { 3 * sin($0 * 2 * .pi) }

    /// The halo's opacity, between a quarter and 0.55 on a seven second cycle: the runbloom.app
    /// gate's own "alive, not animated" breath.
    public static let haloOpacity = Track(period: 7) { 0.4 - 0.15 * cos($0 * 2 * .pi) }

    /// The halo's scale, on the same cycle, so it swells as it brightens.
    public static let haloScale = Track(period: 7) { 1 - 0.06 * cos($0 * 2 * .pi) }

    /// Where the band of light is across the plinth, as a fraction of its width: from well off the
    /// left edge to well off the right in the first four of eleven seconds, eased at both ends,
    /// then parked off the right until it starts again off the left, which nobody can see jump.
    public static let sweep = Track(period: 11) { phase in
        let crossing = 4.0 / 11
        guard phase < crossing else { return 1.3 }
        let t = phase / crossing
        let eased = t * t * (3 - 2 * t)
        return -0.3 + 1.6 * eased
    }

    public static let orbits = [
        Orbit(radiusX: 44, radiusY: 13, tilt: -0.3, period: 10, start: 0),
        Orbit(radiusX: 50, radiusY: 18, tilt: 0.38, period: 12, start: 0.55),
    ]

    /// Every loop, for the tests and for anything that has to pause them all.
    public static var periods: [Double] {
        [float.period, haloOpacity.period, haloScale.period, sweep.period] + orbits.map(\.period)
    }
}
