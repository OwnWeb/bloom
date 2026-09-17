import BloomCore
import BloomProtocol
import Foundation
import Testing

/// A Cloud workspace's wire records read back into the values the Mac's transcript draws.
@MainActor
@Suite struct CloudClientRecordsTests {
    private let date = Date(timeIntervalSince1970: 1_789_000_000)

    @Test func aChatBecomesASessionWithNoLocalWorkspace() {
        let record = ChatRecord(id: "c1", title: "Retries", agent: "codex", model: "gpt-5.5", effort: "high", permissionMode: "acceptEdits",
                                interactionMode: "build", state: "waiting", parentChatID: "c0", lastSeq: 7, createdAt: date, updatedAt: date)
        let session = Session(cloudChat: record)
        #expect(session.id == SessionID("c1"))
        #expect(session.workspaceID == nil)
        #expect(session.agentKind == .codex)
        #expect(session.state == .waiting)
        #expect(session.parentSessionID == SessionID("c0"))
    }

    @Test func aMessageKeepsItsPayloadAuthorAndOrder() throws {
        let record = MessageRecord(cursor: 88, chatID: "c1", seq: 3, kind: "user", payload: .object(["text": .string("Run the tests")]),
                                   author: AuthorRecord(userID: "u1", name: "Alex"), createdAt: date, refID: "r")
        let message = Message(cloudMessage: record, id: -5)
        #expect(message.id == -5)
        #expect(message.kind == .user)
        #expect(message.author == MessageAuthor(userID: "u1", name: "Alex"))
        let payload = try #require(JSONSerialization.jsonObject(with: message.payload) as? [String: String])
        #expect(payload == ["text": "Run the tests"])
    }

    @Test func aPayloadThatWasNotJSONComesBackAsItsText() {
        let record = MessageRecord(cursor: 1, chatID: "c1", seq: 0, kind: "notice", payload: .string("plain"), createdAt: date)
        #expect(String(decoding: Message(cloudMessage: record, id: -1).payload, as: UTF8.self) == "plain")
    }

    @Test func decisionsAreSpelledTheWireWay() {
        #expect(PermissionDecision.allow(scope: .session).cloudAnswer == .allowSession)
        #expect(PermissionDecision.deny(message: "No", endsTurn: true).cloudAnswer == .deny(message: "No", endsTurn: true))
        #expect(PermissionDecision.approvePlan(mode: .acceptEdits).cloudAnswer == .approvePlan(permissionMode: "acceptEdits"))
    }

    @Test func presentationIdsAreNegativeStableAndDistinctPerWorkspace() {
        let one = CloudWorkspaceID("w1")
        let two = CloudWorkspaceID("w2")
        let first = CloudMessageIdentity.id(workspace: one, cursor: 12)
        #expect(first < 0)
        #expect(CloudMessageIdentity.id(workspace: one, cursor: 12) == first)
        #expect(CloudMessageIdentity.id(workspace: two, cursor: 12) != first)
    }
}

@Suite struct CloudQueueTests {
    private let date = Date(timeIntervalSince1970: 1_789_000_000)

    @Test func aQueuedPromptKeepsItsAuthorAndBlock() {
        let record = QueuedPromptRecord(id: "p1", text: "Deploy", author: AuthorRecord(userID: "u2", name: "Alex"), state: "blocked",
                                        blocked: BlockedRecord(limit: "concurrent_machines", message: "Your team has 20 running."), createdAt: date)
        let delivery = Delivery(cloudPrompt: record, chatID: "c1")
        #expect(delivery.id == DeliveryID("p1"))
        #expect(delivery.author?.name == "Alex")
        #expect(delivery.block?.clearsByItself == true)
        #expect(delivery.state == .pending)
    }

    @Test func theCaptionSaysWhyTheFrontIsWaiting() {
        let blocked = Delivery(cloudPrompt: QueuedPromptRecord(id: "p", text: "x", author: nil, state: "blocked",
                                                               blocked: BlockedRecord(limit: "monthly_usage", message: "Over budget."), createdAt: date), chatID: "c")
        #expect(CloudQueueCaption.sentence(first: blocked, isRunning: false, isAwaitingAnswer: false, queueError: nil) == "Over budget. It stays queued until the limit is lifted.")
        let plain = Delivery(cloudPrompt: QueuedPromptRecord(id: "p", text: "x", author: nil, state: "queued", createdAt: date), chatID: "c")
        #expect(CloudQueueCaption.sentence(first: plain, isRunning: true, isAwaitingAnswer: false, queueError: nil) == "Goes when this turn ends.")
        #expect(CloudQueueCaption.sentence(first: plain, isRunning: false, isAwaitingAnswer: false, queueError: nil) == nil)
        #expect(CloudQueueCaption.sentence(first: nil, isRunning: true, isAwaitingAnswer: false, queueError: nil) == nil)
    }
}

@Suite struct CloudChangedFileTests {
    @Test func aChangedFileCrossesTheWireAndComesBack() {
        let file = ChangedFile(path: "a/b.swift", oldPath: "a/old.swift", change: .renamed, additions: 3, deletions: 1, isBinary: false)
        let record = file.record(contentRevision: "r1")
        let back = ChangedFile(cloudRecord: record)
        #expect(back.path == file.path)
        #expect(back.oldPath == file.oldPath)
        #expect(back.change == .renamed)
        #expect(back.additions == 3)
        #expect(back.deletions == 1)
        // The machine measures one row per path from HEAD, so there is no layer to carry.
        #expect(back.layer == nil)
    }

    @Test func aLetterThisVersionDoesNotKnowIsAModification() {
        let record = ChangedFileRecord(path: "a", change: "teleported", additions: 0, deletions: 0, isBinary: false)
        #expect(ChangedFile(cloudRecord: record).change == .modified)
        #expect(ChangedFile.Change(wireName: "untracked") == .untracked)
    }
}
