import BloomCore
import Foundation

/// Running a `!` command typed into this chat, and handing its output to the agent once it has
/// finished. A workspace chat runs it with the variables a terminal pane gets; a conversation
/// outside any workspace runs it in its own folder with none. What the command is and what the
/// agent is told are `ShellCommand`'s; this is the doing.
extension TranscriptModel {
    /// Whether the command was taken. It runs now, or once the agent's turn ends when one is under
    /// way (see `ShellCommand.waitsForTurn`). Refused while another is waiting or running in the
    /// same chat, so the draft stays where it is rather than vanishing into nothing.
    func runShellCommand(_ command: String) -> Bool {
        if usesInteractiveTerminal {
            app.alert = BloomAlert(
                title: "This agent runs in a terminal",
                message: "Open its agent tab and run the command there."
            )
            return false
        }
        guard shellRun == nil else {
            app.notice = BloomNotice(message: "A command is already waiting or running in this chat.")
            return false
        }

        let waits = ShellCommand.waitsForTurn(isTurnRunning: isRunning, isAwaitingQuestion: isAwaitingPermission)
        shellRun = ShellCommand.Run(command: command, isWaiting: waits)
        if !waits { startShellCommand() }
        return true
    }

    /// Starts the command this chat is holding. Called at once from `runShellCommand`, or by
    /// `startWaitingShellCommand` when the turn the command was waiting for has ended.
    func startShellCommand() {
        guard let run = shellRun, shellRunTask == nil else { return }
        shellRun?.isWaiting = false

        let variables = shellVariables
        shellRunTask = Task { @MainActor [weak self, cwd, app] in
            let (ending, output) = await ShellCommandRun.run(run.command, cwd: cwd, variables: variables) { output in
                self?.shellRun?.output = output
            }
            guard let self else { return }
            shellRun = nil
            shellRunTask = nil
            // Stopped by hand is somebody changing their mind, so nothing goes to the agent. So is
            // the chat being closed or archived under it, which cancels this in `terminateNow`.
            guard !Task.isCancelled else {
                app.notice = BloomNotice(message: "The command was stopped. Nothing was sent to the agent.")
                return
            }
            let message = ShellCommand.message(command: run.command, output: output, ending: ending)
            guard await submit(message, queuedAt: run.queuedAt) else {
                app.notice = BloomNotice(message: "The command finished, but its output could not be sent to the agent.")
                return
            }
        }
    }

    private var shellVariables: [String: String] {
        guard let workspace, let model = app.existingModel(for: workspace.id),
              let repo = model.repo, let manager = app.manager else { return [:] }
        return manager.environment(for: model.workspace, repo: repo, port: model.port)
    }
}
