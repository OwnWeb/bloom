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
        #expect(MentionAddress.mentioned(in: "@bloom test", people: Self.people, runningAgent: .claudeCode) == .agent)
        // `@agent` was retired: a handle the control server holds, naming nobody, so it names
        // nobody here too.
        #expect(MentionAddress.mentioned(in: "@agent test", people: Self.people, runningAgent: .claudeCode) == nil)
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
        #expect(audience("@bloom fix the tests", from: .person(Self.seb)) == .agent)
        #expect(audience("@claude fix the tests", from: .person(Self.seb)) == .agent)
        // The one that is running, rather than any of them: this chat is Claude's.
        #expect(audience("@codex fix the tests", from: .person(Self.seb)) == .person(Self.seb))
    }

    /// The name on the window, which is what somebody reaches for before they reach for a role.
    /// The control server reserves the handle, so it can never be a person's.
    @Test("The product's own name addresses the agent too")
    func theProductsNameIsTheAgent() {
        #expect(MentionAddress.token(in: "@bloom fix the tests") == "@bloom")
        #expect(MentionAddress.agentTokens(runningAgent: .codex) == ["bloom", "codex"])
    }

    /// **Retiring a token has three possible failures and this is the gentlest.** `@agent` could
    /// have gone on reaching the agent, which is a word that does not exist still working; it
    /// could have sent to nobody, which loses a message. It does neither: it is a valid handle by
    /// shape that names nobody, so the audience stays exactly where it was and the words are sent
    /// as written. Somebody mid-conversation with a colleague who types it sends that colleague a
    /// message beginning "@agent", which is visible and recoverable.
    @Test("@agent was retired, and it now changes nothing")
    func theOldTokenDoesNothing() {
        #expect(audience("@agent come back", from: .person(Self.seb)) == .person(Self.seb))
        #expect(audience("@agent come back") == .agent)
        // Still a mention by shape, so the composer's menu opens on it and says nobody is called
        // that, rather than the word silently becoming ordinary text.
        #expect(MentionAddress.token(in: "@agent come back") == "@agent")
        #expect(rows("ag").contains { $0.isAgent } == false)
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

    // MARK: - What the menu offers

    private func rows(_ query: String, agent: AgentKind? = .claudeCode) -> [MentionCandidate] {
        MentionAddress.candidates(
            matching: query, people: Self.people, runningAgent: agent, agentName: agent?.label ?? "Agent"
        )
    }

    /// The row somebody could not pick: `@bloom` addressed the agent perfectly well and the menu
    /// said "Nobody here is called blo" while it was being typed.
    @Test("The agent heads the list and answers to every name it has")
    func theAgentIsARow() {
        #expect(rows("").first == .agent(name: "Claude Code"))
        #expect(rows("bl").first?.isAgent == true)
        #expect(rows("cla").first?.isAgent == true)
        // The name it is labelled with, which is what somebody reads before they type.
        #expect(rows("Claude").first?.isAgent == true)
        // And not the one that is not running.
        #expect(rows("codex", agent: .claudeCode).contains { $0.isAgent } == false)
    }

    /// **`bloom` is the one word for the thing itself.** It was `agent` for a day, and the reason
    /// it moved is that `bloom` is the product's name rather than a category.
    @Test("Whichever name found it, picking the agent writes @bloom")
    func theAgentAlwaysWritesTheSameThing() {
        #expect(rows("bl").first?.insertion == "@bloom ")
        #expect(rows("cla").first?.insertion == "@bloom ")
        #expect(rows("seb").first?.insertion == "@sebdd ")
    }

    @Test("People are matched on handle and on name both")
    func peopleAreMatchedTwoWays() {
        #expect(rows("seb") == [.person(Self.seb)])
        #expect(rows("De Deyne") == [.person(Self.seb)])
        #expect(rows("vanderbist") == [.person(Self.alex)])
        // A query that names nobody at all is an empty menu, which the panel draws as a sentence
        // rather than as a list with nothing in it.
        #expect(rows("zz").isEmpty)
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
