import Testing
@testable import BloomClient

@Suite("What the sidebar shows of Bloom Cloud")
struct CloudSidebarPresenceTests {
    @Test("signed in, the list; signed out after using it, the card; never signed in, nothing")
    func shown() {
        #expect(CloudSidebarPresence.decide(isSignedIn: true, hasEverSignedIn: true, isShown: true) == .list)
        #expect(CloudSidebarPresence.decide(isSignedIn: false, hasEverSignedIn: true, isShown: true) == .signInCard)
        #expect(CloudSidebarPresence.decide(isSignedIn: false, hasEverSignedIn: false, isShown: true) == .hidden)
    }

    @Test("dismissed, nothing at all, signed in or out")
    func dismissed() {
        #expect(CloudSidebarPresence.decide(isSignedIn: false, hasEverSignedIn: true, isShown: false) == .hidden)
        #expect(CloudSidebarPresence.decide(isSignedIn: true, hasEverSignedIn: true, isShown: false) == .hidden)
    }

    @Test("shown unless it was turned off")
    func stored() {
        #expect(CloudSidebarPresence.isShown(stored: nil))
        #expect(CloudSidebarPresence.isShown(stored: true))
        #expect(!CloudSidebarPresence.isShown(stored: false))
    }
}
