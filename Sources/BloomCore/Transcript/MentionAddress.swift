import Foundation

/// What a draft's leading `@name` does to who the message goes to.
///
/// **The prefix changes the audience; it does not set it for one message.** Sending `@seb test`
/// addresses Seb and leaves the composer addressed to Seb, so the next message with nothing typed
/// in front of it goes there too, and `@bloom` is what brings it back. That is the whole of
/// "it remembers who you were last talking to", and it is here rather than in a view because both
/// clients have to agree about it and because a rule in a `View` is a rule nothing can test.
///
/// Once a mention is completed, the audience holds the address and the draft holds only the
/// message. A follow-up with no mention still goes to the same audience.
public enum MentionAddress {
    /// The tokens that mean the workspace's agent.
    ///
    /// `bloom`, and the running agent's own name beside it. Bloom runs Claude Code, Codex or Grok
    /// in a chat, so there is no one name to print in a banner the way Amp prints `@amp`.
    ///
    /// **`bloom` is the only word for the thing itself, because it is the product's name rather
    /// than a category**: somebody reaching for what answers reaches for the name on the window
    /// before they reach for a role. The control server reserves the handle, including freeing it
    /// from anybody who held it, so it can never be a person's.
    ///
    /// **`agent` was that word for a day and is gone rather than kept as an alias**, at the
    /// owner's asking. What that costs is written down where it is felt, in `mentioned`: `@agent`
    /// is now an ordinary handle naming nobody, so it changes no audience and the words stay
    /// words. **`@claude`, `@codex` and `@grok` stay**, because they are the agent's own name
    /// rather than a second word for the category, and somebody watching Claude answer will reach
    /// for Claude.
    public static func agentTokens(runningAgent: AgentKind?) -> [String] {
        var tokens = ["bloom"]
        if let alias = runningAgent.map(alias(of:)) { tokens.append(alias) }
        return tokens
    }

    /// What somebody would type for the thing that is answering, which is not its raw value:
    /// `claudeCode` is "claude" to everybody who says it out loud.
    public static func alias(of agent: AgentKind) -> String {
        switch agent {
        case .claudeCode: "claude"
        case .codex: "codex"
        case .grok: "grok"
        case .cursor: "cursor"
        case .openCode: "opencode"
        }
    }

    /// Who this draft is addressed to, given who it was addressed to before.
    ///
    /// - Parameters:
    ///   - draft: what is in the box, as typed.
    ///   - people: everybody who can open this workspace, other than the reader.
    ///   - runningAgent: what is answering in this chat, for its alias.
    ///   - current: who the composer is addressed to now, which is where a draft with no mention
    ///     goes.
    ///
    /// An `@word` that names nobody is left alone: it is a word somebody typed, and rewriting the
    /// audience on a typo would send a message to the wrong reader and say nothing about it.
    public static func audience(
        for draft: String,
        people: [ComposerAudience.Person],
        runningAgent: AgentKind?,
        current: ComposerAudience
    ) -> ComposerAudience {
        mentioned(in: draft, people: people, runningAgent: runningAgent) ?? current
    }

    /// Who this draft NAMES, and nil where it names nobody.
    ///
    /// **Nil rather than `.agent`, which is the whole difference between a feature that remembers
    /// and one that forgets.** A draft with no mention names nobody; where it then goes is the
    /// composer's business, and the composer's answer is "wherever the last one went". A resolver
    /// that answered `.agent` here would send every follow-up back to the agent and undo the
    /// feature while looking like it worked.
    ///
    /// A mention that names nobody is nil too: it is a word somebody typed, and rewriting the
    /// audience on a typo would send a message to the wrong reader without saying so.
    ///
    /// **`@agent` is now one of those**, and it is worth knowing which way it fails. It is a valid
    /// handle by shape and the control server holds it, so it names nobody: the audience is left
    /// exactly where it was and the words are sent as written. So it does not quietly reach the
    /// agent and it does not quietly reach nobody. **It does nothing**, which means somebody who
    /// learned `@agent` while it worked, and is mid-conversation with a colleague, sends that
    /// colleague a message beginning "@agent". That is the price of retiring a token, it is the
    /// gentlest of the three failures available, and it is the one this rule was written for.
    public static func mentioned(
        in draft: String, people: [ComposerAudience.Person], runningAgent: AgentKind?
    ) -> ComposerAudience? {
        guard let token = token(in: draft) else { return nil }
        let name = String(token.dropFirst())
        if agentTokens(runningAgent: runningAgent).contains(name) { return .agent }
        if let person = people.first(where: { $0.handle == name }) { return .person(person) }
        return nil
    }

    /// The draft with the mention at its head taken off, for the button that sends the composer back
    /// to Bloom.
    ///
    /// **The button has to do what typing `@bloom` does, and the draft is half of that.** Setting
    /// the audience alone would leave `@seb` at the front of the box, and the draft names a person
    /// before the audience is asked, so the box would stay terracotta and the next message would
    /// still go to Seb. Only the mention and the one space after it go; whatever was written after
    /// them is the message and stays.
    public static func withoutMention(_ draft: String) -> String {
        guard let token = token(in: draft) else { return draft }
        let leading = draft.prefix { $0 == " " || $0 == "\n" || $0 == "\t" }
        var rest = draft.dropFirst(leading.count + token.count)
        if rest.first == " " { rest = rest.dropFirst() }
        return String(rest)
    }

    /// Consume a completed, recognised address. A local composer has no people, so its `@` keeps
    /// naming files. Wait for whitespace so a short handle cannot steal the beginning of a longer
    /// one while somebody is still typing.
    public static func completedAddress(
        in draft: String, people: [ComposerAudience.Person], runningAgent: AgentKind?
    ) -> (audience: ComposerAudience, message: String)? {
        guard !people.isEmpty,
              let token = token(in: draft),
              let audience = mentioned(in: draft, people: people, runningAgent: runningAgent)
        else { return nil }
        let leading = draft.prefix { $0 == " " || $0 == "\n" || $0 == "\t" }
        let afterToken = draft.dropFirst(leading.count + token.count)
        guard afterToken.first?.isWhitespace == true else { return nil }
        return (audience, withoutMention(draft))
    }

    /// The literal mention at the head of a draft, or nil where there is none.
    ///
    /// **Only at the start**, which is every example there is of this feature and is what keeps
    /// the character's other meaning intact: `@` in the middle of a sentence is a file, and a
    /// composer that guessed between the two would be wrong in whichever direction somebody was
    /// not expecting. Leading whitespace is allowed, because a person who starts with a newline
    /// has still started with the mention.
    /// **A run that could not be a handle is not a mention**, which is what keeps an email address
    /// at the start of a message from addressing anybody: `@freek.spatie.be hello` has a full stop
    /// in it, a handle cannot, so there is no mention here and the words are words. Lowercasing is
    /// not done either: a handle is lowercase by construction, so `@SebDD` is a typo rather than a
    /// match, and a typo that addresses somebody is the thing this whole gate exists to stop.
    public static func token(in draft: String) -> String? {
        let trimmed = draft.drop { $0 == " " || $0 == "\n" || $0 == "\t" }
        guard trimmed.first == "@" else { return nil }
        let token = trimmed.dropFirst().prefix { !$0.isWhitespace }
        guard MentionHandle.isValid(String(token)) || isAgentToken(String(token)) else { return nil }
        return "@" + token
    }

    /// The agent's own tokens are not handles and are not held to their grammar: they are names
    /// this app chose, and they are checked against the list rather than against a shape.
    ///
    /// Every agent's alias is here rather than only the running one, because this gate decides
    /// whether a run of characters is a mention at all; whether it addresses anybody is
    /// `mentioned(in:people:runningAgent:)`, which asks the running agent. That is what makes
    /// `@codex` in a Claude chat a mention that names nobody rather than a word.
    private static func isAgentToken(_ token: String) -> Bool {
        token == "bloom" || AgentKind.allCases.map(alias(of:)).contains(token)
    }

    /// The rows a mention menu shows for what has been typed so far.
    ///
    /// **The agent first**, because it is where most messages go and because a list that buried it
    /// under three colleagues would make the commonest destination the hardest to reach. It is
    /// matched on every token that addresses it and on the name it is labelled with, so `@bl`,
    /// `@cla` and `@Claude` all find the same row. **`@ag` finds nothing**, which is the whole of
    /// what retiring `@agent` looks like from the menu: the word is not offered, so nobody learns
    /// it from here, and somebody who already knows it is told plainly that nobody is called that.
    ///
    /// A person is matched on handle and on name both, because somebody typing `@seb` is as likely
    /// to be reaching for the name they see in the room as for the handle they have to type, and a
    /// menu that only matched handles would look broken to the second kind of person.
    ///
    /// - Parameter agentName: what to call the thing that is answering, which the core has no
    ///   opinion about: `AgentKind.label` for a chat with one running, and whatever the caller
    ///   says for a chat that has not started.
    public static func candidates(
        matching query: String,
        people: [ComposerAudience.Person],
        runningAgent: AgentKind?,
        agentName: String
    ) -> [MentionCandidate] {
        let query = query.lowercased()
        let agent = MentionCandidate.agent(name: agentName)
        let matchesAgent = query.isEmpty
            || agentTokens(runningAgent: runningAgent).contains { $0.hasPrefix(query) }
            || agentName.lowercased().contains(query)
        let matched = people.filter {
            query.isEmpty
                || $0.handle.lowercased().contains(query)
                || $0.name.lowercased().contains(query)
        }
        return (matchesAgent ? [agent] : []) + matched.map(MentionCandidate.person)
    }

    /// Whether a completion menu opened here offers people rather than files.
    ///
    /// Three conditions, and each of them is a rule somebody could get wrong on its own. It has to
    /// be the mention at the head of the draft, because `@` elsewhere is a file. There has to be
    /// somebody to address, so a workspace nobody shares and every local worktree keep the `@`
    /// they have always had. And the moment the query holds a `/` it is a path: a handle cannot
    /// contain one, and `@Sources/Bloom` typed as the first thing in a message is a file mention
    /// that would otherwise have been swallowed by this feature.
    public static func offersPeople(token: ComposerMenu.Token, draft: String, hasPeople: Bool) -> Bool {
        guard hasPeople, !token.query.contains("/") else { return false }
        let head = (draft as NSString).substring(to: token.start)
        return head.allSatisfy { $0 == " " || $0 == "\n" || $0 == "\t" }
    }
}
