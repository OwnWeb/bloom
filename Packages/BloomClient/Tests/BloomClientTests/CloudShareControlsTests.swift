import Foundation
import Testing
@testable import BloomClient

@Suite("What the Share popover lets somebody do")
struct CloudShareControlsTests {
    @Test("Only the owner may change who a Cloud workspace is shared with")
    func onlyTheOwner() {
        #expect(CloudShareControls.canChange(role: "owner"))
        #expect(!CloudShareControls.canChange(role: "collaborator"))
        // A team owner or admin who can see the workspace without being in it.
        #expect(!CloudShareControls.canChange(role: nil))
    }

    @Test("A link says how much of its hour is left")
    func whatIsLeftOfTheHour() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func share(_ seconds: TimeInterval) -> PreviewShare {
            PreviewShare(id: "1", url: URL(string: "https://runbloom.app/p/abc")!,
                         expiresAt: now.addingTimeInterval(seconds))
        }
        #expect(CloudShareControls.expiry(of: share(47 * 60), now: now) == "Expires in 47 minutes")
        #expect(CloudShareControls.expiry(of: share(60), now: now) == "Expires in 1 minute")
        #expect(CloudShareControls.expiry(of: share(20), now: now) == "Expires in under a minute")
        #expect(CloudShareControls.expiry(of: share(-1), now: now) == "Expired")
        #expect(CloudShareControls.expiry(of: share(3 * 3600), now: now) == "Expires in 3 hours")
    }

    @Test("Nothing is drawn where runbloom.app sent no expiry")
    func nothingGuessed() {
        let share = PreviewShare(id: "1", url: URL(string: "https://runbloom.app/p/abc")!)
        #expect(CloudShareControls.expiry(of: share) == nil)
    }
}
