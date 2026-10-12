import BloomCore
import Foundation

/// Running a `!` command typed into one of this workspace's chats, and handing its output to the
/// agent once it has finished. Here rather than on the transcript because the command gets the
/// workspace's variables, the ones a terminal pane gets, and the workspace is what knows them.
/// What the command is and what the agent is told are `ShellCommand`'s; this is the doing.
extension WorkspaceModel {
    /// Whether the command was taken. It runs now, or once the agent's turn ends when one is under
    /// way (see `ShellCommand.waitsForTurn`). Refused while another is waiting or running in the
    /// same chat, so the draft stays where it is rather than vanishing into nothing.
    func runShellCommand(_ command: String, from transcript: TranscriptModel) -> Bool {
        if transcript.usesInteractiveTerminal {
            app.alert = BloomAlert(
                title: "This agent runs in a terminal",
                message: "Open its agent tab and run the command there."
            )
            return false
        }
        guard transcript.shellRun == nil else {
            app.notice = BloomNotice(message: "A command is already waiting or running in this chat.")
            return false
        }

        let waits = ShellCommand.waitsForTurn(
            isTurnRunning: transcript.isRunning, isAwaitingQuestion: transcript.isAwaitingPermission
        )
        transcript.shellRun = ShellCommand.Run(command: command, isWaiting: waits)
        if !waits { startShellCommand(in: transcript) }
        return true
    }

    /// Starts the command the chat is holding. Called at once from `runShellCommand`, or by the
    /// transcript when the turn the command was waiting for has ended.
    func startShellCommand(in transcript: TranscriptModel) {
        guard let run = transcript.shellRun, transcript.shellRunTask == nil else { return }
        transcript.shellRun?.isWaiting = false

        var variables: [String: String] = [:]
        if let repo, let manager = app.manager {
            variables = manager.environment(for: workspace, repo: repo, port: port)
        }
        let cwd = transcript.cwd
        transcript.shellRunTask = Task { @MainActor [weak transcript, app] in
            let (ending, output) = await ShellCommandRun.run(run.command, cwd: cwd, variables: variables) { output in
                transcript?.shellRun?.output = output
            }
            guard let transcript else { return }
            transcript.shellRun = nil
            transcript.shellRunTask = nil
            // Stopped by hand is somebody changing their mind, so nothing goes to the agent. So is
            // the chat being closed or archived under it, which cancels this in `terminateNow`.
            guard !Task.isCancelled else {
                app.notice = BloomNotice(message: "The command was stopped. Nothing was sent to the agent.")
                return
            }
            let message = ShellCommand.message(command: run.command, output: output, ending: ending)
            guard await transcript.submit(message, queuedAt: run.queuedAt) else {
                app.notice = BloomNotice(message: "The command finished, but its output could not be sent to the agent.")
                return
            }
        }
    }
}
