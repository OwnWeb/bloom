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
        // **Skipped is a row here and is nothing locally**, which is not an inconsistency: a local
        // workspace skips setup when the project has no script, which is most of them and is not
        // worth a line. A machine skips it because somebody unticked the box in the create window,
        // and that is worth saying, because the alternative is a workspace that looks exactly like
        // one whose setup happened to do nothing. The row carries Run setup, which is what makes
        // "not now" different from "never".
        if state == .skipped {
            // The machine's own line where it sends one, because it knows which of the two skips
            // this was: a workspace created with the box unticked, or a project with nothing to
            // run. Ours is the fallback rather than the answer, and it is the first of the two,
            // because a machine that ran no setup for want of a script has nothing to say and
            // sends no note.
            return [WorkspaceEvent(
                id: "setup", kind: .setup, outcome: .skipped,
                title: "Setup was not run",
                detail: skipNote(setup),
                log: log
            )]
        }
        // **`pending` is a row here and is nothing locally, for the same reason `skipped` is.** A
        // local workspace is `pending` when it has a setup script it has not run, which is a state
        // nobody is watching; a Cloud workspace is `pending` when its machine exists and has not
        // said what it is doing yet, which is the first thing anybody ever sees of Cloud. Drawing
        // nothing there is what made a new workspace look like nothing happening.
        if state == .pending {
            return [WorkspaceEvent(
                id: "setup", kind: .setup, outcome: .running,
                title: "Setting up", detail: "Waiting for the machine", log: log
            )]
        }
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
        //
        // **And an empty log under a named step is the ordinary case rather than a stall.** Two of
        // the machine's seven steps normally print nothing, and it sets the step BEFORE it does
        // the work, so a named step with no output is a promise it has already kept. Nothing is
        // invented to fill that silence.
        if state == .running, let step = CloudConnectionBanner.stepName(setup.step) {
            // Capitalised because it stands as the row's one line rather than inside a sentence,
            // which is what the banner used it for.
            let heading = String(step.prefix(1).uppercased() + step.dropFirst())
            event.detail = heading
            // What the machine has said beyond the step's own heading: a run starting again
            // because the machine stopped mid-setup, or a step quiet long enough to be worth
            // explaining. Its words rather than ours, because a parallel sentence here would be a
            // second thing to keep in step for ever. See `SetupLogVoice`.
            if let note = SetupLogVoice.newestNote(in: log, excluding: heading) { event.note = note }
        }
        // And the machine's own account of a failure, kept ahead of the generic instruction for
        // the same reason: it was written by the thing that failed.
        if state == .failed, let note = setup.note, !note.isEmpty {
            event.note = [note, SetupFailure.instruction].joined(separator: " ")
        }
        return [event]
    }

    /// What the machine says was skipped, or our own sentence where it says nothing.
    private static func skipNote(_ setup: SetupRecord) -> String {
        let note = setup.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return note.isEmpty ? "This Cloud workspace was created without it." : note
    }

    /// How long it ran, from the two timestamps the machine sends. Nil while it is still going,
    /// which is what the row expects: a duration is something a finished run has.
    private static func duration(of setup: SetupRecord) -> Int? {
        guard let started = setup.startedAt, let finished = setup.finishedAt else { return nil }
        return Int(finished.timeIntervalSince(started) * 1000)
    }
}
