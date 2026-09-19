import Testing
@testable import BloomCore

/// The Bloom Cloud hero's motion: calm, seamless and bounded. See `CloudHeroMotionPlan`.
@Suite("How the Bloom Cloud hero moves")
struct CloudHeroMotionPlanTests {
    @Test("every loop is between six and twelve seconds")
    func slowLoops() {
        for period in CloudHeroMotionPlan.periods {
            #expect((6...12).contains(period), "\(period)")
        }
    }

    /// A value that differs at the two ends of a loop jumps where the loop restarts. The band of
    /// light is the exception, and the next test is why that is fine.
    @Test("every track but the band of light ends where it began")
    func seamless() {
        for track in [CloudHeroMotionPlan.float, .haloOpacity, .haloScale] {
            #expect(abs(track.value(0) - track.value(1)) < 1e-9)
        }
        for orbit in CloudHeroMotionPlan.orbits {
            let start = orbit.position(phase: 0)
            let end = orbit.position(phase: 1)
            #expect(abs(start.x - end.x) < 1e-9 && abs(start.y - end.y) < 1e-9)
        }
    }

    /// The band jumps from right to left only while it is off both edges, where nobody sees it.
    @Test("the band of light only jumps while it is off the plinth")
    func sweepHidden() {
        #expect(CloudHeroMotionPlan.sweep.value(0) < -0.2)
        #expect(CloudHeroMotionPlan.sweep.value(0.999) > 1.2)
    }

    @Test("nothing flashes: the halo stays under two thirds, and the float is a few points")
    func calm() {
        for step in 0...100 {
            let phase = Double(step) / 100
            #expect(CloudHeroMotionPlan.haloOpacity.value(phase) <= 0.56)
            #expect(abs(CloudHeroMotionPlan.float.value(phase)) <= 3.0001)
        }
    }
}
