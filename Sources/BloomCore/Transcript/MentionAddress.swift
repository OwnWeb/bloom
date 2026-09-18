import Foundation

/// What a draft's leading `@name` does to who the message goes to.
///
/// **The prefix changes the audience; it does not set it for one message.** Sending `@seb test`
/// addresses Seb and leaves the composer addressed to Seb, so the next message with nothing typed
/// in front of it goes there too, and `@agent` is what brings it back. That is the whole of
/// "it remembers who you were last talking to", and it is here rather than in a view because both
/// clients have to agree about it and because a rule in a `View` is a rule nothing can test.
///
/// **The mention stays in the message.** It is not consumed by addressing it: the sent bubble
/// shows `@seb test` with the mention in its own colour, because what was typed is what was said.
/// A follow-up carries no mention at all and still goes to Seb, which is why the audience travels
/// beside the text rather than being read back out of it.
public enum MentionAddress {
    /// The tokens that mean the workspace's agent.
    ///
    /// `agent` always, and the running agent's own name beside it. Bloom runs Claude Code, Codex
    /// or Grok in a chat, so there is no one name to print in a banner the way Amp prints `@amp`;
    /// `@agent` is the one a person can always type, and `@claude` is the one they will try first
    /// when Claude is what is answering.
    public static func agentTokens(runningAgent: AgentKind?) -> [String] {
        var tokens = ["agent"]
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
        people: [MessageAudience.Person],
        runningAgent: AgentKind?,
        current: MessageAudience
    ) -> MessageAudience {
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
    public static func mentioned(
        in draft: String, people: [MessageAudience.Person], runningAgent: AgentKind?
    ) -> MessageAudience? {
        guard let token = token(in: draft) else { return nil }
        let name = String(token.dropFirst())
        if agentTokens(runningAgent: runningAgent).contains(name) { return .agent }
        if let person = people.first(where: { $0.handle == name }) { return .person(person) }
        return nil
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
    private static func isAgentToken(_ token: String) -> Bool {
        token == "agent" || AgentKind.allCases.map(alias(of:)).contains(token)
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
