import BloomProtocol
import Foundation
import Testing
@testable import BloomCore

/// The same rule as the author's label, in the second place a person is drawn.
@Suite("What presence calls somebody")
struct RemotePresenceNamesTests {
    private func presence(_ author: MessageAuthor) -> RemotePresence {
        var presence = RemotePresence()
        presence.noteName(author)
        presence.setConnected([author.userID])
        return presence
    }

    /// **An empty name is not a name.** Stored as one it draws a blank chip beside three named
    /// ones, which is the same shape as the unlabelled message that let a colleague's words read
    /// as the reader's own.
    @Test("an empty name is not stored, so the team can fill it")
    func emptyNameIsFilled() {
        let presence = presence(MessageAuthor(userID: "u1", name: ""))

        #expect(presence.records.first?.name == "")
        #expect(presence.records(knownAs: ["u1": "Sebastian"]).first?.name == "Sebastian")
    }

    /// A name somebody actually has wins over the directory's, because it is what their own token
    /// said and it is fresher.
    @Test("a stated name wins over the team's")
    func statedNameWins() {
        let presence = presence(MessageAuthor(userID: "u1", name: "Freek"))

        #expect(presence.records(knownAs: ["u1": "Frederick"]).first?.name == "Freek")
    }

    @Test("whitespace is empty here too")
    func whitespace() {
        let presence = presence(MessageAuthor(userID: "u1", name: "   "))

        #expect(presence.records(knownAs: ["u1": "Sebastian"]).first?.name == "Sebastian")
    }

    /// The team's own fallback: a handle when it has no name either, so what is drawn is never
    /// nothing.
    @Test("a member with no name is drawn by their handle")
    func handleWhenNoName() {
        #expect(WorkspaceMember(userID: "u1", name: "", handle: "sebdd").label == "sebdd")
        #expect(WorkspaceMember(userID: "u1", name: " ", handle: "sebdd").label == "sebdd")
        #expect(WorkspaceMember(userID: "u1", name: "Sebastian", handle: "sebdd").label == "Sebastian")
    }
}
