import Foundation

/// Taking a queued message back into the composer to change it before it goes.
///
/// The sibling of `PendingMessageDiscard`, and deliberately not the same function. Delete refuses
/// to hand the words back when the box is in use, because pasting over what somebody is typing to
/// rescue what they typed earlier trades one loss for another. Edit is somebody asking for that
/// move, so it always hands them back and joins the two rather than choosing between them. The
/// only question both ask is `isPlainText`, which is a fact about the body rather than a policy
/// about the box.
public enum PendingMessageEdit {
    /// Whether Edit may be offered for this one at all.
    ///
    /// A body carrying review chips or attached files cannot come back as text, and there is
    /// nothing honest to draw for it: a disabled button with no explanation says less than no
    /// button, so the row simply does not offer one.
    ///
    /// **And never on somebody else's sentence.** Edit is not "remove this from the queue", it is
    /// "put these words in my composer", where they can be rewritten and sent under my name. In a
    /// shared Cloud workspace the queue holds several people's sentences, and a machine that
    /// permits anybody who may prompt to cancel a queued prompt has answered a different question:
    /// permission to take something out of a queue is not permission to speak in somebody's voice.
    /// Delete stays, because taking a message out of a shared queue is visible to everybody and
    /// puts nobody's words anywhere. The same reasoning already keeps Edit off a message relayed
    /// from another workspace; see `WorkspaceMessageRowView`.
    ///
    /// **Whose it is is `MessageAuthorship`'s question, not this one's**, and it is asked with the
    /// reading account rather than with the absence of an author alone. A queued prompt comes back
    /// from the machine with the account that wrote it on it, the reader's own included, so "it
    /// carries no author, therefore it is mine" would take the pencil off every message the reader
    /// had queued in a Cloud workspace. `reader` is nil for every local queue, where the absence is
    /// the whole of the answer and always was.
    public static func canEdit(_ delivery: Delivery, reader: String? = nil) -> Bool {
        !MessageAuthorship.isFromSomebodyElse(author: delivery.author?.userID, reader: reader)
            && PendingMessageDiscard.canDiscard(delivery)
            && PendingMessageDiscard.isPlainText(delivery.body)
    }

    /// What the composer is left holding once this message has been taken out of the queue.
    ///
    /// The words go at the front, because they were asked for first and reading them from the top
    /// is how they get changed. `composerDraft` blank counts as empty, the same reading
    /// `PendingMessageDiscard.recovery` takes: a box holding three newlines is not something
    /// anybody is in the middle of writing, so it gets the words alone rather than the words and a
    /// blank line and its own whitespace.
    public static func draft(taking delivery: Delivery, into composerDraft: String) -> String {
        guard !composerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return delivery.body
        }
        return delivery.body + "\n\n" + composerDraft
    }

    /// What the owner is told when the message went between pressing Edit and the row being taken
    /// out of the queue. The same race `PendingMessageDiscard.alreadySentSentence` names, said in
    /// this button's own verb so it does not report a delete nobody asked for.
    public static let alreadySentSentence =
        "That message had already gone to the agent, so it could not be edited."
}
