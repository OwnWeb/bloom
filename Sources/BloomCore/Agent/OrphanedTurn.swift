import Foundation

/// A turn the transcript still has open although nothing is running it and nothing is left that
/// could report its end.
///
/// **An open turn holds the queue, and it is meant to.** Between Stop and the result the stopped
/// process prints on its way out, the chat is not running but the turn is not over either, so a
/// message typed in that second waits rather than being written into a process that is dying and
/// then having that process's late result close the turn it started. The rule is
/// `hasActiveTurn && !isRunning` in `TranscriptModel.queuesNextMessage` and in `drain`.
///
/// The rule has no way out of its own, and that is the bug this is for. A stopped `claude` that
/// exited without printing a result left the turn open for the rest of the launch: every message
/// was queued, the drain refused, Try Again called the drain, and there was no Stop to press
/// because nothing was running. `UnreportedStop` is the fix at the root, the runner saying the
/// result the CLI did not. This is the guard behind it, because the queue holding for ever is the
/// failure no path may be allowed to produce again, whatever the next missing ending is.
///
/// Closed only when three things agree that no ending is coming. The chat is not running and is
/// not already wrapping a turn up. The stored session, which the runner owns, says no turn is in
/// flight. And the runner has no process left that could still write one. The last is the one
/// that matters: the session row goes to `cancelled` the moment Stop reaches the runner, while the
/// process it stopped can go on writing for three seconds more.
public enum OrphanedTurn {
    /// Whether the cheap half holds, so the expensive half (reading the session back and asking
    /// the runner) is only paid for on a chat that might need it.
    public static func mightBe(hasActiveTurn: Bool, isRunning: Bool, isSettling: Bool) -> Bool {
        hasActiveTurn && !isRunning && !isSettling
    }

    /// Whether the open turn should be closed now.
    ///
    /// - Parameter isSettling: whether the turn's file changes are being captured or its ending
    ///   is being handled right now, which is somebody else already closing it.
    /// - Parameter storedState: the session's state as the runner last wrote it.
    /// - Parameter endingMayArrive: whether the runner can still deliver the turn's end. False when
    ///   there is no runner at all.
    public static func shouldClose(
        hasActiveTurn: Bool,
        isRunning: Bool,
        isSettling: Bool,
        storedState: SessionState,
        endingMayArrive: Bool
    ) -> Bool {
        mightBe(hasActiveTurn: hasActiveTurn, isRunning: isRunning, isSettling: isSettling)
            && !storedState.isMidTurn
            && !endingMayArrive
    }
}
