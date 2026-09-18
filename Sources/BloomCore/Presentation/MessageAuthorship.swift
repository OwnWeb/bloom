import Foundation

/// Whose message a bubble is, and whether its author is named above it.
///
/// **A message that was not sent by you must never be mistakable for one that was.** The owner
/// watched a teammate say "hey" in a shared Cloud workspace, read it as his own, and had to work
/// out where it had come from: every user bubble was the same fill and the name, where there was
/// one, was small grey type above it. So the fill answers the first question and the name answers
/// the second, in that order of importance.
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

    /// Whether the author's name is drawn above this bubble.
    ///
    /// **Only on the first of a run, the way Messages does it.** A name over every bubble in a
    /// paragraph of them is noise, and the question a reader is asking is "who started saying
    /// this", which changes only when the speaker does.
    ///
    /// - Parameters:
    ///   - author: who wrote it, or nil for the reader's own.
    ///   - previousAuthor: who wrote the message before it, or nil for the reader's own. **The
    ///     previous message rather than the previous row**: an agent answering between two of
    ///     somebody's messages does not make the second one a new run, because the reader can see
    ///     perfectly well that the same person is still talking.
    ///   - name: what the workspace knows to call them.
    ///
    /// An author with no name gets no label. The wire carries a name and an account id and nothing
    /// else, so a person runbloom.app has no name for cannot be introduced here; drawing an empty
    /// label would be a line of nothing above a bubble, which says less than the colour already
    /// does. See `AuthorRecord`.
    public static func showsName(author: String?, previousAuthor: String?, name: String?) -> Bool {
        guard isFromSomebodyElse(author: author) else { return false }
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return author != previousAuthor
    }
}
