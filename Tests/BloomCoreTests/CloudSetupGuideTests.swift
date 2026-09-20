import Foundation
import Testing
@testable import BloomCore

/// The guidance an agent gets before it writes a setup script, and the facts in it that were paid
/// for rather than assembled.
@Suite("What an agent is told about setting a project up")
struct CloudSetupGuideTests {
    /// Each of these cost somebody an afternoon, and a rewrite that drops one puts it back.
    @Test("it names the ports, the app port variable and what a collision looks like")
    func ports() {
        #expect(CloudSetupGuide.text.contains("BLOOM_APP_PORT"))
        #expect(CloudSetupGuide.text.contains("BLOOM_RESERVED_PORTS"))
        #expect(CloudSetupGuide.text.contains("8081"))
        #expect(CloudSetupGuide.text.contains("Address already in use"))
    }

    /// A service that waits for ever, never launching and never failing, is the thing nobody would
    /// guess at.
    @Test("it says a dependency is waited for until it is ready, not until it is launched")
    func readiness() {
        #expect(CloudSetupGuide.text.contains("write a `ready` that can actually pass"))
        #expect(CloudSetupGuide.text.contains("never started, never fails and never restarts"))
    }

    @Test("it says setup runs again after an interrupted machine, where it says setup runs once")
    func idempotence() {
        let text = CloudSetupGuide.text
        let lifecycles = text.range(of: "There are two lifecycles")
        let interrupted = text.range(of: "stopped in the middle of setup runs")
        #expect(lifecycles != nil)
        #expect(interrupted != nil)
        // In the section that claims "once", so a reader meets the exception with the rule rather
        // than two sections later.
        if let lifecycles, let interrupted, let second = text.range(of: "second run you will not witness") {
            #expect(interrupted.lowerBound > lifecycles.lowerBound && interrupted.lowerBound < second.lowerBound)
        }
    }

    @Test("it says a fix on this branch fixes nobody else's workspace")
    func branchScope() {
        #expect(CloudSetupGuide.text.contains("nothing is fixed for anybody else until it is merged"))
    }

    /// The two deliberate omissions. A speed target teaches people to ignore the document, and
    /// advice about restarting a machine is advice an agent would act on about something it does
    /// not own.
    @Test("it sets no speed target and gives no advice about restarting a stuck machine")
    func omissions() {
        let text = CloudSetupGuide.text.lowercased()
        #expect(text.contains("there is no target"))
        #expect(!text.contains("under two minutes"))
        #expect(!text.contains("restart the machine"))
    }

    @Test("the briefing points at it, so an agent finds it without searching")
    func theBriefingNamesIt() {
        let briefing = BridgeBriefing.machine(publicURL: "https://x.sprites.app", appPort: 3000,
                                              reservedPorts: [(8080, "the preview proxy")])

        #expect(briefing.contains("cloud_setup"))
    }

    /// Offered on a Mac too, which is the case it is worth most in: nothing local enforces any of
    /// it, so a project is happy until its first machine.
    @Test("it is offered to a workspace agent and to the owner's own client")
    func bothRoles() {
        let tool = CloudSetupTool()

        #expect(tool.roles.contains(.workspace))
        #expect(tool.roles.contains(.owner))
        #expect(BridgeToolbox.standard.handler(named: CloudSetupTool.name, for: .owner) != nil)
    }
}
