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
    /// **Two ways to be yours, and the second is the one that was missing.** A message with no
    /// author is yours, because the transcript clears the author of anything written by the
    /// account that is reading; every message in a workspace nobody shares is therefore yours,
    /// which is right, because a Mac has one person at it. **And an author that IS you is yours
    /// too**, whether or not anything cleared the field.
    ///
    /// The second half is not defensive tidying. The machine sends your own messages back with
    /// your account still on them, so a client whose whole rule was "there is an author, so it is
    /// not mine" draws your own words in the colour reserved for somebody else's. That rule was
    /// true right up until mentions made it possible to watch one of your messages come back
    /// named. The web client shipped it, the owner reported it, and this is their fix: **be right
    /// whether or not the machine clears the field**, because which of the two is doing the
    /// clearing is not something the reader can see.
    ///
    /// - Parameter reader: the account doing the reading, or nil where nobody is signed in, which
    ///   is every local workspace and a share-link guest. A nil reader matches no author, so the
    ///   answer falls back to the absence alone.
    public static func isFromSomebodyElse(author: String?, reader: String? = nil) -> Bool {
        guard let author else { return false }
        return author != reader
    }

    /// Which of the three fills a bubble carries.
    ///
    /// **The fill answers a different question on each side of the transcript, and that asymmetry
    /// is a decision rather than an oversight.** On your own messages it says who it went to; on
    /// somebody else's it says who it came from. The owner was asked directly and chose to keep
    /// one colour for everything from other people: in a shared workspace the first thing to know
    /// about somebody else's message is that it is theirs, and the first thing to know about your
    /// own is which of the two things you were doing when you wrote it. **Do not tidy this into
    /// one rule.**
    ///
    /// **And it must survive a run.** The address sticks, so four messages to Seb carry a mention
    /// on the first and nothing on the other three. This is read from the audience the message was
    /// sent with rather than from its text, so the fifth message of a run is coloured exactly like
    /// the first. Two earlier attempts at this failed that test, one of them a chip drawn from the
    /// typed mention.
    public enum BubbleFill: Equatable, Sendable {
        /// Yours, to Bloom. The accent, and the default this app has always drawn.
        case own
        /// Yours, to a person. Terracotta: see `PaletteInk.directFill`.
        case ownToPerson
        /// Somebody else's, whoever it was for. The teammate green.
        case somebodyElse
    }

    /// - Parameters:
    ///   - author: who wrote it, or nil for the reader's own.
    ///   - reader: the account doing the reading. See `isFromSomebodyElse(author:reader:)`.
    ///   - audience: who it was addressed to, which is nil for every message written before
    ///     addressing existed and for every message in a workspace nobody shares.
    public static func fill(
        author: String?, reader: String? = nil, audience: MessageAudience? = nil
    ) -> BubbleFill {
        if isFromSomebodyElse(author: author, reader: reader) { return .somebodyElse }
        return audience?.kind == .person ? .ownToPerson : .own
    }

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
    /// Three answers, in order: "you" where it went to the reader, their name from the member
    /// list, then the mention as typed. The last is a good fallback rather than a sad one:
    /// somebody who has left the team since, or who arrived in a snapshot this client has not
    /// fetched the members for, is still `@sebdd` in the sentence that addressed them.
    ///
    /// **And where none of the three can name them, "somebody else" rather than nothing.** The
    /// caption is the only thing on screen saying the agent did not see a message: draw no
    /// addressee and a message to a person looks exactly like a message to the agent, which is the
    /// one confusion this feature cannot afford. A whole sentence beats half of one. The web
    /// client argued this and it is right; the case is nearly unreachable either way, because the
    /// machine writes `mention` on everything.
    public static func addressee(_ audience: MessageAudience?, names: [String: String]) -> String? {
        guard let audience, audience.kind == .person else { return nil }
        if let userID = audience.userID, !clean(names[userID]).isEmpty { return clean(names[userID]) }
        let mention = clean(audience.mention)
        return mention.isEmpty ? "somebody else" : mention
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
    ///   - reader: the account doing the reading, for `isFromSomebodyElse(author:reader:)`.
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
        previousAddressee: String?,
        reader: String? = nil
    ) -> String? {
        let sender = isFromSomebodyElse(author: author, reader: reader) ? clean(name) : ""
        let recipient = clean(addressee)
        guard !sender.isEmpty || !recipient.isEmpty else { return nil }
        // The run is keyed on the pair, and on the author as the wire spells it rather than on
        // "was it mine": your own message following your own message is one run whether or not
        // the machine put your account on both of them.
        guard author != previousAuthor || addressee != previousAddressee else { return nil }
        if sender.isEmpty { return "To " + recipient }
        if recipient.isEmpty { return sender }
        return sender + " to " + recipient
    }

    private static func clean(_ text: String?) -> String {
        text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
