import Testing
@testable import BloomCore

@Suite("Whose message a bubble is, and who it was for")
struct MessageAuthorshipTests {
    private static let names = ["u1": "you", "u2": "Seb De Deyne", "u3": "Alex Vanderbist"]

    private func caption(
        author: String? = nil, name: String? = nil, to addressee: String? = nil,
        after previousAuthor: String? = "none", previousAddressee: String? = nil
    ) -> String? {
        MessageAuthorship.caption(
            author: author, name: name, addressee: addressee,
            previousAuthor: previousAuthor, previousAddressee: previousAddressee
        )
    }

    @Test("A message with no author is the reader's own")
    func yourOwnIsUnlabelled() {
        #expect(!MessageAuthorship.isFromSomebodyElse(author: nil))
        // Every local message there has ever been: no author, no audience, no caption.
        #expect(caption(after: nil) == nil)
    }

    @Test("Somebody else's is theirs whatever it is called")
    func theirsIsTheirs() {
        #expect(MessageAuthorship.isFromSomebodyElse(author: "u2"))
        // The bug this was written for: an account with no name is still not you, and the colour
        // says so even where the caption cannot.
        #expect(caption(author: "u2", name: "") == nil)
        #expect(caption(author: "u2", name: nil) == nil)
        #expect(caption(author: "u2", name: "   ") == nil)
    }

    @Test("Somebody else's message names both ends")
    func bothEnds() {
        #expect(caption(author: "u2", name: "Seb De Deyne") == "Seb De Deyne")
        #expect(caption(author: "u2", name: "Seb De Deyne", to: "Alex Vanderbist")
            == "Seb De Deyne to Alex Vanderbist")
        // The one this matters most for: somebody talking to the person reading.
        #expect(caption(author: "u2", name: "Seb De Deyne", to: "you") == "Seb De Deyne to you")
        // A teammate nobody can name is still captioned by who they were talking to, which is the
        // half of the sentence this client does know.
        #expect(caption(author: "u2", name: nil, to: "Alex Vanderbist") == "To Alex Vanderbist")
    }

    @Test("Your own names the far end only, because you know which of the two you are")
    func yourOwnNamesTheFarEnd() {
        #expect(caption(to: "Seb De Deyne") == "To Seb De Deyne")
    }

    @Test("The caption goes on the first of a run and not on the rest")
    func onlyTheFirstOfARun() {
        #expect(caption(author: "u2", name: "Seb", after: nil) == "Seb")
        #expect(caption(author: "u2", name: "Seb", after: "u2") == nil)
        // A third person after them starts a run of their own.
        #expect(caption(author: "u3", name: "Alex", after: "u2") == "Alex")
        // And so does the same person turning from the agent to somebody else, which is the whole
        // reason the run is keyed on the pair rather than on the speaker.
        #expect(caption(author: "u2", name: "Seb", to: "you", after: "u2") == "Seb to you")
        #expect(caption(author: "u2", name: "Seb", to: "you", after: "u2", previousAddressee: "you") == nil)
        #expect(caption(to: "Seb De Deyne", after: nil, previousAddressee: "Seb De Deyne") == nil)
    }

    // MARK: - Who the audience names

    @Test("The agent is not an addressee, which is what keeps a local transcript captionless")
    func theAgentIsNotDrawn() {
        #expect(MessageAuthorship.addressee(nil, names: Self.names) == nil)
        #expect(MessageAuthorship.addressee(MessageAudience(kind: .agent), names: Self.names) == nil)
    }

    @Test("A person is named, and the mention is what a client with no member list has")
    func aPersonIsNamed() {
        #expect(MessageAuthorship.addressee(
            MessageAudience(kind: .person, userID: "u2", mention: "@sebdd"), names: Self.names
        ) == "Seb De Deyne")
        // Somebody who has left the team since, or a snapshot whose members this client has not
        // fetched: the mention as typed is still true about the sentence that addressed them.
        #expect(MessageAuthorship.addressee(
            MessageAudience(kind: .person, userID: "u9", mention: "@sebdd"), names: Self.names
        ) == "@sebdd")
        // And a person this cannot name at all is no addressee rather than half a sentence.
        #expect(MessageAuthorship.addressee(
            MessageAudience(kind: .person, userID: "u9"), names: Self.names
        ) == nil)
    }
}
