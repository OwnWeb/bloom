import BloomProtocol
import Foundation
import Testing
@testable import BloomCore

/// A message addressed to a person, and the one rule that makes the feature real.
@Suite("Addressing a message")
struct MessageAudienceTests {
    @Test("the mention is taken off what the agent reads and left on what the transcript keeps")
    func strippingIsForTheAgentOnly() {
        #expect(MessageAudience.textForAgent("@agent Fix the server", mention: "@agent") == "Fix the server")
        #expect(MessageAudience.textForAgent("@claude  Fix it", mention: "@claude") == "Fix it")
        // Only a prefix. A mention in the middle is somebody's text and is left alone.
        #expect(MessageAudience.textForAgent("Ask @agent about it", mention: "@agent") == "Ask @agent about it")
        #expect(MessageAudience.textForAgent("Fix the server", mention: nil) == "Fix the server")
    }

    /// A delivery is the only thing that reaches an agent, and `sent` is the single place that
    /// decides what it says.
    @Test("a delivery hands the agent the text without the mention")
    func deliverySends() {
        let delivery = Delivery(targetSessionID: SessionID("01k5bx7j9d3v2r8q6m4n0p1s2w"),
                                body: "@agent run the tests", audienceMention: "@agent")

        #expect(delivery.sent == "run the tests")
        #expect(delivery.body == "@agent run the tests", "the transcript keeps what was typed")
    }

    /// **An audience this machine does not understand must not read as the agent.** A newer client
    /// inventing a kind would otherwise have its private message handed straight to the model.
    @Test("an unknown audience kind is refused rather than treated as the agent")
    func unknownKind() {
        #expect(MessageAudience(AudienceRecord(kind: "channel")) == nil)
        #expect(MessageAudience(AudienceRecord(kind: "person", userID: "u1"))?.isPrivateToPeople == true)
        #expect(MessageAudience(AudienceRecord(kind: "agent"))?.isPrivateToPeople == false)
    }

    /// Absent means the agent, which is every message written before this existed.
    @Test("no audience at all is the agent's")
    func absentIsTheAgent() {
        let message = Message(sessionID: SessionID("01k5bx7j9d3v2r8q6m4n0p1s2w"), seq: 1, kind: .user, payload: Data())

        #expect(message.audience == nil)
        #expect(message.audience?.isPrivateToPeople != true)
    }
}
