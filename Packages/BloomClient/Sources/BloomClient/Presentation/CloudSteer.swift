import Foundation

/// Whether a queued message in a Cloud chat may be sent in place of the turn that is running.
///
/// **Locally Steer is one person's business, and on a machine it is not.** A worktree on this Mac
/// has one person at it, so stopping the turn and sending the message that was pressed is a
/// rearrangement of that person's own work. A Cloud chat's queue is the machine's, shared, and
/// drained in the order it arrived: the same button there can stop somebody else's turn, jump their
/// place, or both. So it was refused outright, which was right while there was no rule and is not a
/// rule.
///
/// **What makes it safe is that the machine drains its own queue.** Bloom cannot say "this one
/// next": it can cancel a queued prompt, stop a turn, and send. So the three things below are not
/// caution, they are what has to be true for those three calls to add up to a Steer at all.
///
/// 1. **The message is the reader's.** Sending somebody else's words early is not a rearrangement,
///    it is speaking for them.
/// 2. **The turn running now is the reader's.** Stopping it costs whoever started it the work it
///    has done, and that is theirs to decide.
/// 3. **It is the only thing queued.** After the cancel and the stop, the machine starts whatever
///    is at the front of its queue. With nothing there, the send that follows is the next turn,
///    which is exactly what Steer promises; with anything there, the message would go to the back
///    of a queue it was already in, and the button would have stopped a turn for nothing.
///
/// Nothing is drawn when this says no. `PendingTurnRowView` leaves the item out of the menu rather
/// than greying it, because an item with no explanation says less than no item at all.
public enum CloudSteer {
    public static func canSteer(
        isRunning: Bool,
        promptIsReaders: Bool,
        runningTurnIsReaders: Bool,
        queued: Int
    ) -> Bool {
        isRunning && promptIsReaders && runningTurnIsReaders && queued == 1
    }
}
