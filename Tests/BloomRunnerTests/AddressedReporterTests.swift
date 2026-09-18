import BloomCore
import Foundation
import Synchronization
import Testing
@testable import BloomRunner

/// Telling runbloom.app somebody was addressed, which is what causes mail.
@Suite("Reporting that somebody was addressed")
struct AddressedReporterTests {
    private func report(userID: String = "user-seb", connected: Bool = false,
                        from: AddressedReport.Sender = .member("user-freek")) -> AddressedReport {
        AddressedReport(sessionID: SessionID("01k5bx7j9d3v2r8q6m4n0p1s2w"), userID: userID,
                        connected: connected, sentAt: Date(timeIntervalSince1970: 1_700_000_000), from: from)
    }

    @Test("the body carries the id, the sender and the machine's own verdict on who was here")
    func bodyShape() throws {
        let body = report(connected: true).body

        #expect(body["message_id"]?.stringValue?.isEmpty == false)
        #expect(body["sent_at"]?.stringValue == "2023-11-14T22:13:20.000Z")
        #expect(body["from"]?["kind"]?.stringValue == "member")
        #expect(body["from"]?["user_id"]?.stringValue == "user-freek")
        #expect(body["addressed"]?[0]?["user_id"]?.stringValue == "user-seb")
        #expect(body["addressed"]?[0]?["connected"]?.boolValue == true)
    }

    /// **The machine says what happened; the server decides what it means.** A guest's message is
    /// reported and mails nobody, and that policy lives in one deploy rather than in a release to
    /// every machine.
    @Test("a guest is reported as a guest, with no user id")
    func guestSender() {
        let body = report(from: .guest).body

        #expect(body["from"]?["kind"]?.stringValue == "guest")
        #expect(body["from"]?["user_id"] == nil)
    }

    /// A share link needs no account and can be handed to anybody, so what it mints is not a member.
    @Test("a share subject is a guest however it is spelled")
    func shareIsAGuest() {
        #expect(AddressedReport.Sender.of(MessageAuthor(userID: "share:01k5", name: "")) == .guest)
        #expect(AddressedReport.Sender.of(nil) == .guest)
        #expect(AddressedReport.Sender.of(MessageAuthor(userID: "user-1", name: "Freek")) == .member("user-1"))
    }

    /// The row is the queue, so nothing is lost by failing and the same id goes again, which is
    /// what makes a retry free at the other end.
    @Test("a report that cannot be sent is kept and sent again with the same id")
    func retriesWithTheSameID() async throws {
        let store = try Store(path: SetupTestSupport.directory("addressed") + "/bloom.sqlite")
        let sent = Mutex([String]())
        let failing = Mutex(true)
        let waited = Mutex(0)
        let stored = report()
        try await store.recordAddressed(stored)
        let reporter = AddressedReporter(store: store, sleep: { _ in waited.withLock { $0 += 1 } }) { body in
            let id = try #require(JSONValue.parse(body)?["message_id"]?.stringValue)
            if failing.withLock({ $0 }) {
                sent.withLock { $0.append(id) }
                throw RunbloomError.unreachable("not yet")
            }
            sent.withLock { $0.append(id) }
        }

        await reporter.start()
        #expect(await SetupTestSupport.eventually { sent.withLock { !$0.isEmpty } })
        failing.withLock { $0 = false }
        #expect(await SetupTestSupport.eventually { ((try? await store.unsentAddressedReports())?.isEmpty ?? false) })
        await reporter.stop()

        #expect(sent.withLock { $0 }.allSatisfy { $0 == stored.id }, "the same id every time, or the mail is sent twice")
        #expect(try await store.unsentAddressedReports().isEmpty)
    }
}
