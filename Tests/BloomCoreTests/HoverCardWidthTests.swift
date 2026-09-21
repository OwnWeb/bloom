import CoreGraphics
import Testing
@testable import BloomCore

@Suite("Hover card width")
struct HoverCardWidthTests {
    @Test("Content between the two bounds is drawn at its own width")
    func widthFollowsTheContent() {
        #expect(HoverCardWidth.fits(content: 412) == 412)
    }

    @Test("Content narrower than the floor is drawn at the floor")
    func widthNeverGoesBelowTheFloor() {
        #expect(HoverCardWidth.fits(content: 120) == HoverCardWidth.minimum)
        #expect(HoverCardWidth.fits(content: 0) == HoverCardWidth.minimum)
    }

    @Test("Content wider than the ceiling is drawn at the ceiling")
    func widthNeverGoesAboveTheCeiling() {
        #expect(HoverCardWidth.fits(content: 900) == HoverCardWidth.ceiling)
    }

    @Test("A fractional width is rounded up to a whole point")
    func widthIsWhole() {
        #expect(HoverCardWidth.fits(content: 412.25) == 413)
    }

    @Test("A width that is not a number lands on the floor")
    func widthOfNothingAtAll() {
        #expect(HoverCardWidth.fits(content: .nan) == HoverCardWidth.minimum)
        #expect(HoverCardWidth.fits(content: .infinity) == HoverCardWidth.minimum)
    }

    @Test("The bounds are ordered and remain card-sized")
    func boundsAreSane() {
        #expect(HoverCardWidth.minimum < HoverCardWidth.ceiling)
        #expect(HoverCardWidth.minimum > 260)
    }
}
