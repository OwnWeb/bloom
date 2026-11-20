import Testing
import Foundation
@testable import BloomCore

/// Shapes measured on 2.3.2. See "Steering" in `docs/OPENCODE.md`.
@Suite("OpenCode steering")
struct OpenCodeSteerTests {
    private func chunk(_ text: String, messageID: String?, thought: Bool = false) -> ACPSessionUpdate {
        var update: [String: JSONValue] = [
            "sessionUpdate": .string(thought ? "agent_thought_chunk" : "agent_message_chunk"),
            "content": .object(["type": .string("text"), "text": .string(text)]),
        ]
        if let messageID { update["messageId"] = .string(messageID) }
        return ACPSessionUpdate(
            sessionID: "ses_1",
            kind: thought ? .thought(text) : .text(text),
            raw: .object(update)
        )
    }

    @Test("the steering reply is read by its outcome, and anything else is no answer")
    func outcomes() {
        #expect(OpenCodeSteerOutcome.decode(.object(["outcome": .string("injected")])) == .injected)
        #expect(OpenCodeSteerOutcome.decode(.object([
            "outcome": .string("promptRequired"), "reason": .string("noRunningTurn"),
        ])) == .promptRequired)
        #expect(OpenCodeSteerOutcome.decode(.object(["outcome": .string("queued")])) == nil)
        #expect(OpenCodeSteerOutcome.decode(.object([:])) == nil)
    }

    @Test("steered words stay unread through the message that was streaming, and are read by the next")
    func readingNeedsANewMessage() {
        var reading = OpenCodeSteerReading()
        reading.observe(chunk("Working", messageID: "msg_1"))
        reading.taken()
        #expect(reading.isUnread)
        reading.observe(chunk(" on it.", messageID: "msg_1"))
        reading.observe(chunk("thinking", messageID: "msg_1:reasoning:0", thought: true))
        #expect(reading.isUnread)
        reading.observe(chunk("Noted.", messageID: "msg_2"))
        #expect(!reading.isUnread)
    }

    @Test("a thought of a new message is an answer too")
    func newThoughtIsAnAnswer() {
        var reading = OpenCodeSteerReading()
        reading.taken()
        reading.observe(chunk("considering", messageID: "msg_2:reasoning:0", thought: true))
        #expect(!reading.isUnread)
    }

    @Test("a second steer before the answer waits on the same answer")
    func twoSteersOneAnswer() {
        var reading = OpenCodeSteerReading()
        reading.observe(chunk("a", messageID: "msg_1"))
        reading.taken()
        reading.observe(chunk("b", messageID: "msg_1"))
        reading.taken()
        #expect(reading.isUnread)
        reading.observe(chunk("c", messageID: "msg_2"))
        #expect(!reading.isUnread)
    }

    @Test("a steer sent before the turn showed anything waits past the message being streamed")
    func steerBeforeAnyChunk() {
        var reading = OpenCodeSteerReading()
        reading.taken()
        reading.observe(chunk("still the first step", messageID: "msg_1"))
        #expect(reading.isUnread)
        reading.observe(chunk("the reply", messageID: "msg_2"))
        #expect(!reading.isUnread)
    }

    @Test("after a silent tool call, the next message is the reply")
    func toolCallNamesTheStep() {
        var reading = OpenCodeSteerReading()
        reading.observe(OpenCodeFixture.toolUpdate([
            "toolCallId": .string("call_1"), "name": .string("shell"), "status": .string("pending"),
        ], isUpdate: false))
        reading.taken()
        reading.observe(chunk("the reply", messageID: "msg_2"))
        #expect(!reading.isUnread)
    }

    @Test("a steer that was not taken leaves nothing waiting, unless another was taken")
    func notTaken() {
        var reading = OpenCodeSteerReading()
        reading.observe(chunk("a", messageID: "msg_1"))
        reading.steered()
        #expect(reading.isOnWire)
        reading.settled(taken: false)
        #expect(!reading.isOnWire)
        #expect(!reading.isUnread)

        reading.taken()
        reading.steered()
        reading.settled(taken: false)
        #expect(reading.isUnread)
    }

    @Test("two steers on the wire: one failing does not forget the other, which was taken")
    func concurrentSteers() {
        var reading = OpenCodeSteerReading()
        reading.observe(chunk("a", messageID: "msg_1"))
        reading.steered()
        reading.steered()
        reading.settled(taken: false)
        #expect(reading.isUnread)
        reading.settled(taken: true)
        #expect(reading.isUnread)
    }

    @Test("a reply that comes while a later steer is on the wire leaves the later words waiting")
    func replyDuringALaterSteer() {
        var reading = OpenCodeSteerReading()
        reading.observe(chunk("a", messageID: "msg_1"))
        reading.taken()
        reading.steered()
        reading.observe(chunk("reply to the first", messageID: "msg_2"))
        reading.settled(taken: true)
        #expect(reading.isUnread)
        reading.observe(chunk("reply to the second", messageID: "msg_3"))
        #expect(!reading.isUnread)
    }

    @Test("a chunk without a message id proves nothing, and a reset forgets the steer")
    func noIdAndReset() {
        var reading = OpenCodeSteerReading()
        reading.taken()
        reading.observe(chunk("anonymous", messageID: nil))
        #expect(reading.isUnread)
        reading.reset()
        #expect(!reading.isUnread)
    }

    @Test("the notice reads back as its sentence, and other notices are not it")
    func noteRoundTrip() {
        #expect(OpenCodeSteerNote.sentence(fromNote: OpenCodeSteerNote.note) == OpenCodeSteerNote.sentence)
        #expect(OpenCodeSteerNote.sentence(fromNote: ConversationNotResumed.note) == nil)
        #expect(ConversationNotResumed.sentence(fromNote: OpenCodeSteerNote.note) == nil)
        #expect(WorkspaceLifecycleNote(payload: OpenCodeSteerNote.note) == nil)
    }

    @Test("a new message id closes the answer being streamed, so the reply to a steer is its own row")
    func newMessageClosesTheBlock() {
        var translation = OpenCodeTranslation(context: OpenCodeTranslation.Context(cwd: "/tmp/w"))
        _ = translation.translate(.sessionReady(OpenCodeSession(id: "ses_1")))
        _ = translation.translate(.update(chunk("Before.", messageID: "msg_1")))
        _ = translation.translate(.update(chunk("thought", messageID: "msg_1:reasoning:0", thought: true)))
        let same = translation.translate(.update(chunk(" More.", messageID: "msg_1")))
        // Text after a thought already closes the thought; the same message closes nothing else.
        #expect(same.filter { if case .assistantText = $0 { true } else { false } }.isEmpty)

        let next = translation.translate(.update(chunk("After.", messageID: "msg_2")))
        let closed = next.compactMap { if case .assistantText(let block) = $0 { block.text } else { nil } }
        #expect(closed == [" More."])
    }

    @Test("closing the open blocks writes what was streamed so far, once")
    func closeOpenBlocks() {
        var translation = OpenCodeTranslation(context: OpenCodeTranslation.Context(cwd: "/tmp/w"))
        _ = translation.translate(.sessionReady(OpenCodeSession(id: "ses_1")))
        _ = translation.translate(.update(chunk("So far.", messageID: "msg_1")))
        let closed = translation.closeOpenBlocks()
        #expect(closed.count == 1)
        guard case .assistantText(let block) = closed.first else {
            Issue.record("expected the text so far")
            return
        }
        #expect(block.text == "So far.")
        #expect(translation.closeOpenBlocks().isEmpty)
    }
}

private extension OpenCodeSteerReading {
    /// A steer sent and taken, as the runner records one that replied `injected`.
    mutating func taken() {
        steered()
        settled(taken: true)
    }
}
