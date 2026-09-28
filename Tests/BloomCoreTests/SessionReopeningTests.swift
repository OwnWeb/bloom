import Testing
import Foundation
@testable import BloomCore

private func chat(
    _ name: String,
    messages: Int = 1,
    closedAt: Date,
    agent: AgentKind = .claudeCode,
    id: SessionID = .new()
) -> ClosedChat {
    ClosedChat(id: id, title: name, agentKind: agent, messageCount: messages, closedAt: closedAt)
}

/// What a workspace offers to reopen, and what reopening writes.
///
/// The bug behind every test here: closing a chat stamps `archived_at` and nothing ever cleared
/// it, so a chat closed by accident was unreachable from inside the app for good. The owner lost
/// one holding 13,872 messages, all of them still in the database, and got it back by typing
/// `UPDATE sessions SET archived_at = NULL` into sqlite3.
@Suite("Session reopening")
struct SessionReopeningTests {
    // MARK: - Which chats are offered

    @Test("the newest closures come first")
    func newestFirst() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let offered = SessionReopening.offered([
            chat("older", closedAt: now.addingTimeInterval(-3600)),
            chat("newest", closedAt: now),
            chat("middle", closedAt: now.addingTimeInterval(-60)),
        ])

        #expect(offered.map(\.title) == ["newest", "middle", "older"])
    }

    /// The cap is what keeps this a section of a menu rather than a list, and it is also the only
    /// way a chat leaves the offer. Nothing here expires.
    @Test("only the ten most recent are offered")
    func capsAtTen() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let chats = (0..<25).map { chat("chat \($0)", closedAt: now.addingTimeInterval(Double(-$0))) }

        let offered = SessionReopening.offered(chats)

        #expect(offered.count == SessionReopening.limit)
        #expect(offered.map(\.title) == (0..<10).map { "chat \($0)" })
    }

    /// The decision that separates this from a window: age is drawn, never used to filter. A
    /// chat closed a year ago is still the eleventh thing anybody would look for, and the whole
    /// point of the feature is that doing nothing cannot take it away.
    @Test("age never disqualifies a chat")
    func ageDoesNotExpireAnOffer() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ancient = chat("last year", messages: 13_872, closedAt: now.addingTimeInterval(-400 * 86_400))

        let offered = SessionReopening.offered([ancient])

        #expect(offered.map(\.title) == ["last year"])
    }

    /// An empty chat has nothing to recover and the same menu offers a new one three rows up.
    @Test("a chat with no messages is not offered")
    func emptyChatsAreDropped() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let offered = SessionReopening.offered([
            chat("empty", messages: 0, closedAt: now),
            chat("used", messages: 1, closedAt: now.addingTimeInterval(-60)),
        ])

        #expect(offered.map(\.title) == ["used"])
    }

    /// `sorted(by:)` is not stable, and two chats closed in one gesture carry the same stamp, so
    /// without the tie-break the strip could draw them in a different order on every pass.
    @Test("chats closed at the same moment keep one order")
    func tiedClosuresAreOrderedByID() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let first = chat("a", closedAt: now, id: SessionID("aaa"))
        let second = chat("b", closedAt: now, id: SessionID("bbb"))

        #expect(SessionReopening.offered([second, first]).map(\.title) == ["a", "b"])
        #expect(SessionReopening.offered([first, second]).map(\.title) == ["a", "b"])
    }

    // MARK: - The words

    /// The count is interpolated rather than spelled out, because `Counted` writes it with the
    /// reader's own thousands separator and this suite runs on a Mac whose locale writes 13.872.
    /// What is pinned here is the order, the separator and the age, which is this type's work;
    /// the number itself is `CountedTests`'s.
    @Test("a row says its agent, its size and its age")
    func subtitleReadsAsOneSentence() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let closed = chat("Chat 3", messages: 13_872, closedAt: now.addingTimeInterval(-2 * 3600))

        let subtitle = SessionReopening.subtitle(closed, now: now)

        #expect(subtitle == "Claude Code \u{00B7} \(13_872.formatted()) messages \u{00B7} closed 2 hours ago")
    }

    /// **Every case the sentence has**, because it is written out by hand now rather than handed to
    /// a formatter, and because the two `subtitle` tests only ever exercise two of them.
    @Test("the age reads as a person would say it, at every distance")
    func ageAtEveryDistance() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func age(_ seconds: TimeInterval) -> String {
            SessionReopening.age(of: now.addingTimeInterval(-seconds), from: now)
        }

        #expect(age(0) == "just now")
        #expect(age(59) == "just now")
        #expect(age(60) == "1 minute ago")
        #expect(age(59 * 60) == "59 minutes ago")
        #expect(age(3_600) == "1 hour ago")
        #expect(age(2 * 3_600) == "2 hours ago")
        #expect(age(86_400) == "yesterday")
        #expect(age(2 * 86_400) == "2 days ago")
        #expect(age(6 * 86_400) == "6 days ago")
        #expect(age(7 * 86_400) == "last week")
        #expect(age(14 * 86_400) == "2 weeks ago")
    }

    /// The count agrees with the number, which is the whole reason `Counted` exists.
    @Test("one message is not one messages")
    func subtitleCountsInSingular() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let closed = chat("Chat 2", messages: 1, closedAt: now.addingTimeInterval(-60), agent: .codex)

        #expect(
            SessionReopening.subtitle(closed, now: now)
                == "Codex \u{00B7} 1 message \u{00B7} closed 1 minute ago"
        )
    }

    /// A menu item with nothing written on it cannot be picked on purpose.
    @Test("an untitled chat is drawn as Chat")
    func blankTitleFallsBack() {
        let closed = chat("   ", closedAt: Date())
        #expect(SessionReopening.title(closed) == PaneNaming.chat)
        #expect(SessionReopening.title(chat("  Review  ", closedAt: Date())) == "Review")
    }

    // MARK: - What the store offers and what reopening writes

    @Test("closed chats come back newest first, counted", .tags(.persistence), .scratchDirectory)
    func storeOffersClosedChatsWithTheirSize() async throws {
        let store = try makeTestStore("reopen-offer")
        let workspace = try await makeWorkspace(in: store)

        let big = try await store.upsert(Session(workspaceID: workspace.id, title: "Big"))
        let small = try await store.upsert(Session(workspaceID: workspace.id, title: "Small"))
        let open = try await store.upsert(Session(workspaceID: workspace.id, title: "Still open"))
        for _ in 0..<3 { try await append(to: big.id, in: store) }
        try await append(to: small.id, in: store)
        try await append(to: open.id, in: store)

        // Small goes first, Big a minute later, so Big is the newer closure.
        _ = try await store.update(sessionID: small.id) {
            $0.archivedAt = Date(timeIntervalSince1970: 1_700_000_000)
        }
        _ = try await store.update(sessionID: big.id) {
            $0.archivedAt = Date(timeIntervalSince1970: 1_700_000_060)
        }

        let closed = try await store.closedSessions(workspaceID: workspace.id, limit: 10)

        #expect(closed.map(\.title) == ["Big", "Small"])
        #expect(closed.map(\.messageCount) == [3, 1])
        #expect(!closed.contains { $0.title == "Still open" })
    }

    /// The SQL limit and the in-memory offer use the same tie-break. Otherwise eleven chats
    /// closed in one gesture could choose a different ten on different reads before Swift ever
    /// had a chance to order the rows it received.
    @Test("the bounded store list has a stable tie-break", .tags(.persistence), .scratchDirectory)
    func storeBoundIsStableForTiedClosures() async throws {
        let store = try makeTestStore("reopen-bound-tie")
        let workspace = try await makeWorkspace(in: store)
        let closedAt = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0...SessionReopening.limit {
            let id = SessionID(String(format: "closed-%02d", index))
            _ = try await store.upsert(Session(id: id, workspaceID: workspace.id, title: id.rawValue))
            try await append(to: id, in: store)
            _ = try await store.update(sessionID: id) { $0.archivedAt = closedAt }
        }

        let closed = try await store.closedSessions(
            workspaceID: workspace.id,
            limit: SessionReopening.limit
        )

        #expect(closed.map(\.id.rawValue) == (0..<SessionReopening.limit).map { String(format: "closed-%02d", $0) })
    }

    /// Clearing `archived_at` on a crew member or a side conversation would hand back a chat the
    /// tab strip never draws: reachable in the database, invisible in the app, which is the bug
    /// this feature exists to fix wearing a different coat.
    ///
    /// The parent is left open on purpose. `sessions_keep_side_conversations` promotes a chat's
    /// side conversations the moment that chat is archived, so a side conversation only stays one
    /// while its parent is still there, and closing the parent first would have made this fixture
    /// prove nothing.
    @Test("crew members and side conversations are not offered", .tags(.persistence), .scratchDirectory)
    func storeOffersOnlyChatsTheStripDraws() async throws {
        let store = try makeTestStore("reopen-tabbable")
        let workspace = try await makeWorkspace(in: store)

        let parent = try await store.upsert(Session(workspaceID: workspace.id, title: "Parent"))
        let crew = try await store.upsert(Session(
            workspaceID: workspace.id, parentSessionID: parent.id, title: "cascade-read"
        ))
        let aside = try await store.upsert(Session(
            workspaceID: workspace.id, sideConversationParentID: parent.id, title: "Aside"
        ))
        let ordinary = try await store.upsert(Session(workspaceID: workspace.id, title: "Chat 2"))
        for session in [crew, aside, ordinary] {
            try await append(to: session.id, in: store)
            _ = try await store.update(sessionID: session.id) { $0.archivedAt = Date() }
        }

        let closed = try await store.closedSessions(workspaceID: workspace.id, limit: 10)

        #expect(closed.map(\.title) == ["Chat 2"])
        #expect(try await store.session(id: parent.id)?.archivedAt == nil)
    }

    /// The write that brings a chat back, and the columns it must leave alone. A session row has
    /// two writers, and the value a menu was built from is a reading taken when the pointer
    /// crossed a button: putting it back whole would overwrite `agent_session_id`, which is the
    /// id `--resume` is built from.
    @Test("reopening clears the stamp and touches no other column", .tags(.persistence), .scratchDirectory)
    func reopeningWritesOneColumn() async throws {
        let store = try makeTestStore("reopen-write")
        let workspace = try await makeWorkspace(in: store)
        let created = Date(timeIntervalSince1970: 1_600_000_000)
        let updated = Date(timeIntervalSince1970: 1_700_000_000)
        let session = try await store.upsert(Session(
            id: SessionID("rich-chat"),
            workspaceID: workspace.id,
            title: "Long one",
            agentSessionID: "f93932c9-cf0b-40d8-881c-ac75db3f8740",
            model: "gpt-5.5",
            effort: "high",
            agentKind: .codex,
            permissionMode: .autoReview,
            interactionMode: .build,
            state: .failed,
            sortOrder: 7,
            createdAt: created,
            updatedAt: updated,
            lastReadSeq: 8,
            inputTokens: 4_200,
            outputTokens: 900,
            costUSD: 1.25,
            contextTokens: 18_000
        ))
        try await append(to: session.id, in: store)
        _ = try await store.update(sessionID: session.id) { $0.archivedAt = Date() }
        #expect(try await store.sessions(workspaceID: workspace.id).isEmpty)
        let closed = try #require(try await store.session(id: session.id))

        let reopened = try #require(try await store.reopenSession(id: session.id))

        var expected = closed
        expected.archivedAt = nil
        #expect(reopened == expected, "archived_at is the only session field reopening changes")
        // And it is back in the list the tab strip is built from.
        #expect(try await store.sessions(workspaceID: workspace.id).map(\.id) == [session.id])
        // With its messages, which were never deleted. This is the whole promise.
        #expect(try await store.messageCount(sessionID: session.id) == 1)
    }

    /// A chat whose workspace was archived and its records deleted while the menu stood open.
    @Test("reopening a row that has gone answers nothing", .tags(.persistence), .scratchDirectory)
    func reopeningAMissingRowIsNotAnInsert() async throws {
        let store = try makeTestStore("reopen-missing")
        #expect(try await store.reopenSession(id: SessionID("never-existed")) == nil)
    }

    /// The trigger that promotes a closed chat's side conversations fires on the way in and not on
    /// the way out, and that is right: those chats are tabs of their own now, and pulling them
    /// back under a parent would take them out of the strip without asking.
    @Test("promoted side conversations stay promoted", .tags(.persistence), .scratchDirectory)
    func reopeningDoesNotReclaimSideConversations() async throws {
        let store = try makeTestStore("reopen-side")
        let workspace = try await makeWorkspace(in: store)
        let parent = try await store.upsert(Session(workspaceID: workspace.id, title: "Parent"))
        let aside = try await store.upsert(Session(
            workspaceID: workspace.id, sideConversationParentID: parent.id, title: "Aside"
        ))

        _ = try await store.update(sessionID: parent.id) { $0.archivedAt = Date() }
        #expect(try await store.session(id: aside.id)?.sideConversationParentID == nil)

        _ = try await store.reopenSession(id: parent.id)

        #expect(try await store.session(id: aside.id)?.sideConversationParentID == nil)
    }
}

// MARK: - Fixtures

private func makeWorkspace(in store: Store) async throws -> Workspace {
    let repo = try await store.upsert(Repo(name: "r", path: "/tmp/r-\(UUID().uuidString)"))
    return try await store.upsert(Workspace(
        repoID: repo.id, name: "w", branch: "b", path: "/tmp/w-\(UUID().uuidString)", baseBranch: "main"
    ))
}

private func append(to sessionID: SessionID, in store: Store) async throws {
    _ = try await store.appendNext(
        sessionID: sessionID, kind: .user, payload: Data("{}".utf8)
    )
}
