import Testing
@testable import BloomClient

@Suite("What the sidebar shows of Bloom Cloud")
struct CloudSidebarPresenceTests {
    /// Whether this Mac has ever signed in does not come into it: the card is how somebody not
    /// using Bloom Cloud gets to say so.
    @Test("signed in, the list; signed out, the card")
    func shown() {
        #expect(CloudSidebarPresence.decide(isSignedIn: true, isShown: true) == .list)
        #expect(CloudSidebarPresence.decide(isSignedIn: false, isShown: true) == .signInCard)
    }

    @Test("dismissed, nothing at all, signed in or out")
    func dismissed() {
        #expect(CloudSidebarPresence.decide(isSignedIn: false, isShown: false) == .hidden)
        #expect(CloudSidebarPresence.decide(isSignedIn: true, isShown: false) == .hidden)
    }

    @Test("shown unless it was turned off")
    func stored() {
        #expect(CloudSidebarPresence.isShown(stored: nil))
        #expect(CloudSidebarPresence.isShown(stored: true))
        #expect(!CloudSidebarPresence.isShown(stored: false))
    }
}
