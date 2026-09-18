import Testing
@testable import BloomCore

@Suite("Whose message a bubble is")
struct MessageAuthorshipTests {
    @Test("A message with no author is the reader's own")
    func yourOwnIsUnlabelled() {
        #expect(!MessageAuthorship.isFromSomebodyElse(author: nil))
        #expect(!MessageAuthorship.showsName(author: nil, previousAuthor: "u2", name: "Freek"))
    }

    @Test("Somebody else's is theirs whatever it is called")
    func theirsIsTheirs() {
        #expect(MessageAuthorship.isFromSomebodyElse(author: "u2"))
        // The bug this was written for: an account with no name is still not you.
        #expect(MessageAuthorship.isFromSomebodyElse(author: "u2"))
        #expect(!MessageAuthorship.showsName(author: "u2", previousAuthor: nil, name: ""))
        #expect(!MessageAuthorship.showsName(author: "u2", previousAuthor: nil, name: nil))
        #expect(!MessageAuthorship.showsName(author: "u2", previousAuthor: nil, name: "   "))
    }

    @Test("The name goes on the first of a run and not on the rest")
    func onlyTheFirstOfARun() {
        #expect(MessageAuthorship.showsName(author: "u2", previousAuthor: nil, name: "Seb"))
        #expect(!MessageAuthorship.showsName(author: "u2", previousAuthor: "u2", name: "Seb"))
        // A third person after them starts a run of their own.
        #expect(MessageAuthorship.showsName(author: "u3", previousAuthor: "u2", name: "Alex"))
        // And so does the same person again after you have spoken.
        #expect(MessageAuthorship.showsName(author: "u2", previousAuthor: nil, name: "Seb"))
    }
}
