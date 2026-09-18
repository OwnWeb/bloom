import Foundation
import Testing
@testable import BloomCore

@Suite("Addressing a message to a person")
struct MentionAddressTests {
    private static let seb = ComposerAudience.Person(id: CloudUserID("u2"), handle: "sebdd", name: "Seb De Deyne")
    private static let alex = ComposerAudience.Person(id: CloudUserID("u3"), handle: "alex", name: "Alex Vanderbist")
    private static let people = [seb, alex]

    private func audience(_ draft: String, from current: ComposerAudience = .agent) -> ComposerAudience {
        MentionAddress.audience(for: draft, people: Self.people, runningAgent: .claudeCode, current: current)
    }

    @Test("A mention at the start addresses that person")
    func theMentionAddresses() {
        #expect(audience("@sebdd test") == .person(Self.seb))
        #expect(audience("  @alex have a look") == .person(Self.alex))
        // A handle is lowercase by construction, so this is a typo rather than a match, and a typo
        // that addresses somebody is the thing the grammar exists to stop.
        #expect(audience("@SebDD test") == .agent)
    }

    /// The web client found this before either of us shipped it: a full stop is not in the handle
    /// alphabet, so an email at the start of a sentence is words rather than a short mention.
    @Test("An email address at the start addresses nobody")
    func anEmailIsNotAMention() {
        #expect(MentionAddress.token(in: "@freek.spatie.be hello") == nil)
        #expect(audience("@freek.spatie.be hello", from: .person(Self.alex)) == .person(Self.alex))
        // And the grammar itself, which is the control server's.
        #expect(MentionHandle.isValid("sebdd"))
        #expect(MentionHandle.isValid("seb-dd_2"))
        #expect(!MentionHandle.isValid("2seb"))
        #expect(!MentionHandle.isValid("s"))
        #expect(!MentionHandle.isValid("Seb"))
        #expect(!MentionHandle.isValid(String(repeating: "a", count: 31)))
    }

    /// Nil rather than the agent, which is the difference between a feature that remembers and one
    /// that forgets: where a draft with no mention goes is the composer's business.
    @Test("A draft with no mention names nobody")
    func namingNobodyIsNotNamingTheAgent() {
        #expect(MentionAddress.mentioned(in: "carry on", people: Self.people, runningAgent: .claudeCode) == nil)
        #expect(MentionAddress.mentioned(in: "@nobody test", people: Self.people, runningAgent: .claudeCode) == nil)
        #expect(MentionAddress.mentioned(in: "@agent test", people: Self.people, runningAgent: .claudeCode) == .agent)
    }

    /// The whole of "it remembers who you were last talking to": the prefix changes the audience
    /// rather than setting it for one message, so the next message with nothing typed in front of
    /// it goes to the same person.
    @Test("With no mention, it goes wherever the last one went")
    func theAddressSticks() {
        #expect(audience("carry on", from: .person(Self.seb)) == .person(Self.seb))
        #expect(audience("carry on") == .agent)
    }

    @Test("The agent has a token that always works, and its own name beside it")
    func theAgentIsAddressableToo() {
        #expect(audience("@agent fix the tests", from: .person(Self.seb)) == .agent)
        #expect(audience("@claude fix the tests", from: .person(Self.seb)) == .agent)
        // The one that is running, rather than any of them: this chat is Claude's.
        #expect(audience("@codex fix the tests", from: .person(Self.seb)) == .person(Self.seb))
    }

    /// A typo must not send a message to the wrong reader, and must not silently send it to the
    /// agent either. It goes where the last one went, and the word stays a word.
    @Test("A mention that names nobody changes nothing")
    func anUnknownHandleIsJustAWord() {
        #expect(audience("@sebd test", from: .person(Self.alex)) == .person(Self.alex))
        #expect(audience("@nobody test") == .agent)
    }

    @Test("Only at the start, because @ in the middle of a sentence is a file")
    func onlyAtTheStart() {
        #expect(audience("have a look @sebdd") == .agent)
        #expect(MentionAddress.token(in: "look at @sebdd") == nil)
        #expect(MentionAddress.token(in: "@") == nil)
        #expect(MentionAddress.token(in: "@sebdd test") == "@sebdd")
    }

    // MARK: - Which menu an @ opens

    private func token(_ draft: String) -> ComposerMenu.Token {
        ComposerMenu.mentionToken(in: draft, caret: (draft as NSString).length) ?? .init(start: 0, length: 0, query: "")
    }

    @Test("People at the head of the draft, files everywhere else")
    func theMenuKnowsWhichItIs() {
        #expect(MentionAddress.offersPeople(token: token("@se"), draft: "@se", hasPeople: true))
        #expect(!MentionAddress.offersPeople(token: token("look at @se"), draft: "look at @se", hasPeople: true))
    }

    /// The two cases that keep the character's other meaning: a workspace with nobody to address,
    /// which is every local worktree, and a path typed as the first thing in a message.
    @Test("Files win where there is nobody to address, and as soon as it is a path")
    func filesKeepTheirCharacter() {
        #expect(!MentionAddress.offersPeople(token: token("@se"), draft: "@se", hasPeople: false))
        #expect(!MentionAddress.offersPeople(
            token: token("@Sources/Bloom"), draft: "@Sources/Bloom", hasPeople: true
        ))
    }
}
