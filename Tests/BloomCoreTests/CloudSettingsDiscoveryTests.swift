import Foundation
import Testing
@testable import BloomCore

@Suite("Hidden Bloom Cloud settings")
struct CloudSettingsDiscoveryTests {
    @Test("the tenth General tap inside ten seconds reveals the pane")
    func tenTaps() {
        var discovery = CloudSettingsDiscovery()
        let start = Date(timeIntervalSince1970: 1_000)

        for tap in 0..<9 {
            let revealed = discovery.record(isGeneral: true, at: start.addingTimeInterval(Double(tap)))
            #expect(!revealed)
        }

        let revealed = discovery.record(isGeneral: true, at: start.addingTimeInterval(9))
        #expect(revealed)
    }

    @Test("another row breaks the sequence")
    func interrupted() {
        var discovery = CloudSettingsDiscovery()
        let start = Date(timeIntervalSince1970: 1_000)

        for tap in 0..<9 {
            _ = discovery.record(isGeneral: true, at: start.addingTimeInterval(Double(tap) / 2))
        }
        _ = discovery.record(isGeneral: false, at: start.addingTimeInterval(5))

        let revealed = discovery.record(isGeneral: true, at: start.addingTimeInterval(5.5))
        #expect(!revealed)
    }

    @Test("an expired window starts again from one")
    func expired() {
        var discovery = CloudSettingsDiscovery()
        let start = Date(timeIntervalSince1970: 1_000)

        for tap in 0..<9 {
            _ = discovery.record(isGeneral: true, at: start.addingTimeInterval(Double(tap)))
        }

        let revealed = discovery.record(isGeneral: true, at: start.addingTimeInterval(11))
        #expect(!revealed)
    }

    @Test("a sign in or a temporary reveal makes the pane visible")
    func visibility() {
        #expect(!CloudSettingsDiscovery.isVisible(isSignedIn: false, isRevealed: false))
        #expect(CloudSettingsDiscovery.isVisible(isSignedIn: true, isRevealed: false))
        #expect(CloudSettingsDiscovery.isVisible(isSignedIn: false, isRevealed: true))
    }
}
