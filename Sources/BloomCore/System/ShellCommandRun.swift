import Foundation

/// Running a `!` command from the composer. See `ShellCommand`.
///
/// **`StreamingProcess`, the way setup scripts run, and neither of the other two ways Bloom has.**
/// `Shell.run` returns nothing until the process has ended, so a two minute `npm test` would look
/// like a composer that had hung. A terminal tab streams, but a command typed into a shell there
/// reports no exit status (see `RunScriptActivity`), and finishing is what hands the output to the
/// agent.
///
/// **Stdin is closed straight away.** Nobody can type into this process, so a command that reads
/// stdin (`cat` with no file, a confirmation prompt) gets end of file and goes on, rather than
/// waiting for ever on a pipe nobody writes to.
public enum ShellCommandRun {
    /// How long a stopped command has to exit after SIGTERM before it is killed, as for setup.
    static let stopGrace: Duration = .seconds(5)

    /// Runs `command` in the user's shell, handing each line to `onLine` in order, and returns how
    /// it ended. Cancelling the calling task stops it.
    ///
    /// `variables` are the workspace's own, the ones a terminal pane gets. The environment crosses
    /// `untrustedProcess` like a terminal's does: the command is the user's, but `npm test` runs the
    /// repository's code, and that is exactly what the boundary is for.
    public static func run(
        _ command: String,
        cwd: String,
        variables: [String: String],
        onLine: @escaping @MainActor @Sendable (String) -> Void
    ) async -> ProcessEnding {
        // A PATH that arrives a moment late is a `command not found` for something the user has
        // installed. Usually free: the probe finished long before anybody typed a `!`.
        await LoginShellPath.ready()
        let process = StreamingProcess(
            executable: LoginShell.path(),
            arguments: ["-c", command],
            cwd: cwd,
            environment: ProviderCredentialEnvironment.untrustedProcess(Shell.environment(extra: variables))
        )
        // A launch failure is reported through `lines`, which is read below.
        try? process.start()
        process.closeStdin()

        await withTaskCancellationHandler {
            do {
                for try await line in process.lines { await onLine(line) }
            } catch {
                await onLine("\(error)")
            }
        } onCancel: {
            process.terminate()
            Task.detached {
                try? await Task.sleep(for: stopGrace)
                process.kill()
            }
        }
        return await process.ending
    }
}
