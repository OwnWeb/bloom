import Foundation

/// Whose message a bubble is, who it was for, and whether either is said above it.
///
/// **A message that was not sent by you must never be mistakable for one that was.** The owner
/// watched a teammate say "hey" in a shared Cloud workspace, read it as his own, and had to work
/// out where it had come from: every user bubble was the same fill and the name, where there was
/// one, was small grey type above it. So the fill answers the first question and the caption
/// answers the second, in that order of importance.
///
/// **"Who said this" and "who was it for" are different questions**, and in a workspace several
/// people are talking in they are both worth answering. Somebody else's message names both ends,
/// "Freek Van der Herten to Seb De Deyne", and your own names the far end only, "To Seb De Deyne",
/// because you already know which of the two you are. The caption is the only place the addressee
/// appears: **the fill is keyed on the sender alone**, so a message to a person and a message to
/// the agent are the same colour and being able to see at a glance that yours cannot do what
/// somebody else's does is the point of keeping it that way.
///
/// Here rather than in the row because the web client draws the same conversation, and two clients
/// working the rule out separately is how one of them ends up labelling every bubble and the other
/// labelling none. It is also the one part of this a test can hold.
public enum MessageAuthorship {
    /// Whether this message was sent by somebody else, which is the only thing the colour depends
    /// on.
    ///
    /// A message with no author is the reader's own. That is the client's own convention rather
    /// than the wire's: the transcript clears the author of anything written by the account that
    /// is reading, so what is left carries a name because it belongs to somebody else. Every
    /// message in a workspace nobody shares is therefore the reader's, which is right: a Mac has
    /// one person at it.
    public static func isFromSomebodyElse(author: String?) -> Bool { author != nil }

    /// What to call whoever a message was addressed to, or nil where the caption says nothing
    /// about it.
    ///
    /// Nil for the agent and for every message written before audiences existed, which is what
    /// keeps a local transcript captionless: talking to the agent is the default and a label on
    /// every bubble saying so would be a line of noise per message.
    ///
    /// - Parameter names: what this workspace calls each account, by id. The reader's own entry is
    ///   "you", because a message addressed to the person reading it is the one the caption is
    ///   most worth drawing for.
    ///
    /// The mention as typed is the fallback, and it is a good one: somebody who has left the team
    /// since, or who arrived in a snapshot this client has not fetched the members for, is still
    /// `@sebdd` in the sentence that addressed them. A person this cannot name at all is drawn as
    /// no addressee rather than as an empty half of a sentence.
    public static func addressee(_ audience: MessageAudience?, names: [String: String]) -> String? {
        guard let audience, audience.kind == .person else { return nil }
        if let userID = audience.userID, let name = names[userID], !clean(name).isEmpty {
            return clean(name)
        }
        let mention = clean(audience.mention)
        return mention.isEmpty ? nil : mention
    }

    /// The caption above a bubble, or nil where it has none.
    ///
    /// **Only on the first of a run, the way Messages does it.** A caption over every bubble in a
    /// paragraph of them is noise, and the question a reader is asking is "who started saying this,
    /// and to whom", which changes only when one of those two does. The run is keyed on the pair,
    /// so the same person turning from the agent to a teammate is a new run and gets a new caption.
    ///
    /// - Parameters:
    ///   - author: who wrote it, or nil for the reader's own.
    ///   - name: what the workspace knows to call them.
    ///   - addressee: what to call who it was for, from `addressee(_:names:)`.
    ///   - previousAuthor: who wrote the message before it, or nil for the reader's own. **The
    ///     previous message rather than the previous row**: an agent answering between two of
    ///     somebody's messages does not make the second one a new run, because the reader can see
    ///     perfectly well that the same person is still talking.
    ///   - previousAddressee: who that one was for, by the same rule.
    ///
    /// An author with no name gets no name in the caption. The wire carries a name and an account
    /// id and nothing else, so a person runbloom.app has no name for cannot be introduced here;
    /// drawing an empty label would be a line of nothing above a bubble, which says less than the
    /// colour already does. They can still be captioned by who they were talking to, which is more
    /// than nothing and is the half of the sentence this client does know. See `AuthorRecord`.
    public static func caption(
        author: String?,
        name: String?,
        addressee: String?,
        previousAuthor: String?,
        previousAddressee: String?
    ) -> String? {
        let sender = isFromSomebodyElse(author: author) ? clean(name) : ""
        let recipient = clean(addressee)
        guard !sender.isEmpty || !recipient.isEmpty else { return nil }
        guard author != previousAuthor || addressee != previousAddressee else { return nil }
        if sender.isEmpty { return "To " + recipient }
        if recipient.isEmpty { return sender }
        return sender + " to " + recipient
    }

    private static func clean(_ text: String?) -> String {
        text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
