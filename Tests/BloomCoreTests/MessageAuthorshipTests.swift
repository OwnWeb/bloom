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

    /// The bug the web client shipped and the owner reported: the machine sends your own messages
    /// back with your account still on them, so "there is an author, so it is not mine" drew his
    /// own words in the colour reserved for somebody else's.
    @Test("A message whose author is you is yours, cleared or not")
    func yourOwnAccountIsStillYou() {
        #expect(!MessageAuthorship.isFromSomebodyElse(author: "u1", reader: "u1"))
        #expect(MessageAuthorship.isFromSomebodyElse(author: "u2", reader: "u1"))
        // Nobody signed in: every local workspace, and a share-link guest. The absence is all
        // there is to go on, and it is the answer it always was.
        #expect(MessageAuthorship.isFromSomebodyElse(author: "u2", reader: nil))
        #expect(!MessageAuthorship.isFromSomebodyElse(author: nil, reader: nil))
        // And the caption agrees with the colour, which is the half that would otherwise have
        // read "Freek Van der Herten to Seb De Deyne" over Freek's own sentence.
        #expect(MessageAuthorship.caption(
            author: "u1", name: "Freek Van der Herten", addressee: "Seb De Deyne",
            previousAuthor: nil, previousAddressee: nil, reader: "u1"
        ) == "To Seb De Deyne")
        // A colleague writing to a third person still names both ends. A fix that deletes both is
        // not a fix.
        #expect(MessageAuthorship.caption(
            author: "u2", name: "Seb De Deyne", addressee: "Freek Van der Herten",
            previousAuthor: nil, previousAddressee: nil, reader: "u1"
        ) == "Seb De Deyne to Freek Van der Herten")
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

    // MARK: - Which fill a bubble carries

    /// **The test two earlier attempts failed.** The address sticks, so a run of four messages to
    /// Seb carries a mention on the first and nothing on the other three. Anything derived from
    /// the typed text is therefore right once and wrong three times; this is read from the
    /// audience the message was sent with, so the fifth message of a run looks like the first.
    @Test("The fill survives a run, because it is read from the audience and not from the words")
    func theFifthMessageLooksLikeTheFirst() {
        let toSeb = MessageAudience(kind: .person, userID: "u2", mention: "@sebdd")
        let follows = MessageAudience(kind: .person, userID: "u2")
        #expect(MessageAuthorship.fill(author: nil, audience: toSeb) == .ownToPerson)
        // No mention in the text at all, four messages later.
        #expect(MessageAuthorship.fill(author: nil, audience: follows) == .ownToPerson)
    }

    /// **The fill answers a different question on each side and that is the owner's decision.**
    /// Yours says who it went to; somebody else's says who it came from, whoever they wrote to.
    @Test("Three fills, and the two sides are asked different questions")
    func theTwoSidesAreAskedDifferentThings() {
        let toSeb = MessageAudience(kind: .person, userID: "u2", mention: "@sebdd")
        #expect(MessageAuthorship.fill(author: nil) == .own)
        #expect(MessageAuthorship.fill(author: nil, audience: MessageAudience(kind: .agent)) == .own)
        #expect(MessageAuthorship.fill(author: "u1", reader: "u1", audience: toSeb) == .ownToPerson)
        // Somebody else's, addressed to a person, is still the one colour: theirs.
        #expect(MessageAuthorship.fill(author: "u2", reader: "u1", audience: toSeb) == .somebodyElse)
        #expect(MessageAuthorship.fill(author: "u2", reader: "u1") == .somebodyElse)
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
        // And a person none of the three can name is still said to be a person, because the
        // caption is the only thing saying the agent did not see this. Drawing nothing would make
        // it look like a message to the agent.
        #expect(MessageAuthorship.addressee(
            MessageAudience(kind: .person, userID: "u9"), names: Self.names
        ) == "somebody else")
        #expect(caption(to: "somebody else") == "To somebody else")
    }
}
