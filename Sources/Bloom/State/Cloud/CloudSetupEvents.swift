import BloomClient
import BloomCore
import BloomProtocol
import Foundation

/// A machine's setup, as the rows at the head of a transcript.
///
/// **Setup is part of the conversation, in both kinds of workspace.** It had a tab of its own here
/// for one day, on the argument that it is the one thing a Cloud workspace has and a local one does
/// not. The owner put the two side by side and said it plainly: locally setup is a row in the
/// transcript, where the reader already is, and a tab only one kind of workspace has is exactly the
/// feeling this whole slice exists to remove. So the machine's setup goes through the same
/// `WorkspaceEvent` the local one does, drawn by the same row, in the same place in the reading
/// order.
///
/// What the machine gives that a worktree does not is used inside that row rather than as a reason
/// to keep a pane: a named step while it runs, and the last lines of a failure without having to
/// ask for the whole log.
enum CloudSetupEvents {
    /// The events for a Cloud workspace's transcript, which is the setup row and nothing else: a
    /// machine has no merges or renames of Bloom's own to report.
    static func events(setup: SetupRecord?, log: String) -> [WorkspaceEvent] {
        guard let setup, let state = SetupState(rawValue: setup.state) else { return [] }
        guard var event = WorkspaceEvent.setup(
            state: state,
            log: log,
            durationMS: duration(of: setup),
            // The machine sends no exit status. `SetupDiagnosis` reads the log either way, and a
            // status it has not got is exactly what `nil` is for.
            status: nil
        ) else { return [] }

        // The step, which is the one thing the machine knows and a worktree does not: the local
        // row shows the last line of the log while it runs, and "Cloning the repository" is a
        // better answer than whatever git last printed.
        if state == .running, let step = CloudConnectionBanner.stepName(setup.step) {
            // Capitalised because it stands as the row's one line rather than inside a sentence,
            // which is what the banner used it for.
            event.detail = step.prefix(1).uppercased() + step.dropFirst()
        }
        // And the machine's own account of a failure, kept ahead of the generic instruction for
        // the same reason: it was written by the thing that failed.
        if state == .failed, let note = setup.note, !note.isEmpty {
            event.note = [note, SetupFailure.instruction].joined(separator: " ")
        }
        return [event]
    }

    /// How long it ran, from the two timestamps the machine sends. Nil while it is still going,
    /// which is what the row expects: a duration is something a finished run has.
    private static func duration(of setup: SetupRecord) -> Int? {
        guard let started = setup.startedAt, let finished = setup.finishedAt else { return nil }
        return Int(finished.timeIntervalSince(started) * 1000)
    }
}
