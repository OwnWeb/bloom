import Testing
@testable import BloomCore

/// The Bloom Cloud hero's motion: calm, seamless and bounded. See `CloudHeroMotionPlan`.
@Suite("How the Bloom Cloud hero moves")
struct CloudHeroMotionPlanTests {
    /// Written out rather than with leading dots: the array's element type is `Track`, and
    /// `.yaw` on it does not exist, which the app target's build never sees because only the core
    /// suite compiles this file. That cost one red CI run.
    private let tracks: [CloudHeroMotionPlan.Track] = [
        CloudHeroMotionPlan.yaw, CloudHeroMotionPlan.pitch, CloudHeroMotionPlan.roll,
        CloudHeroMotionPlan.lift, CloudHeroMotionPlan.sheenTilt,
    ]

    @Test("every loop is between eight and fourteen seconds")
    func slowLoops() {
        for period in CloudHeroMotionPlan.periods {
            #expect((8...14).contains(period), "\(period)")
        }
    }

    /// A value that differs at the two ends of a loop jumps where the loop restarts. The sheen is
    /// the exception, and the next test is why that is fine.
    @Test("every track but the sheen ends where it began")
    func seamless() {
        for track in tracks {
            #expect(abs(track.value(0) - track.value(1)) < 1e-9)
        }
    }

    /// The light leaves the icon and comes back on the other side while it is invisible.
    @Test("the sheen only jumps while it is off the icon and at no strength")
    func sheenHidden() {
        #expect(CloudHeroMotionPlan.sheen.value(0) < -1)
        #expect(CloudHeroMotionPlan.sheen.value(0.999) > 1)
        #expect(CloudHeroMotionPlan.sheenOpacity.value(0) < 1e-9)
        #expect(CloudHeroMotionPlan.sheenOpacity.value(0.999) < 1e-9)
    }

    @Test("nothing lurches: the turn stays under nine degrees and the sheen under two thirds")
    func calm() {
        for step in 0...200 {
            let pose = CloudHeroMotionPlan.pose(atSeconds: Double(step) / 4)
            #expect(abs(pose.yaw) <= 0.158, "yaw \(pose.yaw)")
            #expect(abs(pose.pitch) <= 0.106)
            #expect(abs(pose.roll) <= 0.027)
            #expect(pose.sheenOpacity <= 0.65)
            #expect(pose.sheenOpacity >= 0)
        }
    }

    /// A shadow that did not move with the light would give the depth away at once.
    @Test("the shadow leans away from the turn, and spreads as the icon leans")
    func shadowFollows() {
        let level = CloudHeroMotionPlan.shadow(for: .init(yaw: 0, pitch: 0, roll: 0, lift: 0, sheen: 0, sheenOpacity: 0))
        let turned = CloudHeroMotionPlan.shadow(for: .init(yaw: 0.157, pitch: 0, roll: 0, lift: 0, sheen: 0, sheenOpacity: 0))
        #expect(turned.offsetX < level.offsetX, "the shadow goes the other way from the face")
        #expect(turned.radius > level.radius, "and softens as it leans")
        #expect(turned.opacity < level.opacity)

        let glow = CloudHeroMotionPlan.glowOffset(for: .init(yaw: 0.157, pitch: 0.105, roll: 0, lift: 0, sheen: 0, sheenOpacity: 0))
        #expect(glow.x > 0 && glow.y > 0, "the water's light travels with the icon's")
    }
}
