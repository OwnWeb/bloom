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

    /// How often the output is handed to the main actor while the command runs.
    ///
    /// Not once per line: `! yes` prints faster than the main actor can take a hop and a redraw per
    /// line, and the stream behind `lines` buffers without bound, so a per line hand-off grew memory
    /// until Stop. The output is kept here, off the main actor, and a snapshot goes over at most this
    /// often, which is still faster than anybody reads.
    static let publishInterval: Duration = .milliseconds(100)

    /// Runs `command`, handing what it has printed so far to `onOutput` as it goes, and returns how
    /// it ended with everything it printed. The first line is handed over as soon as it arrives.
    /// Cancelling the calling task stops it.
    ///
    /// `variables` are the workspace's own, the ones a terminal pane gets. The environment crosses
    /// `untrustedProcess` like a terminal's does: the command is the user's, but `npm test` runs the
    /// repository's code, and that is exactly what the boundary is for.
    ///
    /// `shell` is the user's, because the command is written in its syntax. A parameter so the
    /// suite can name `/bin/sh` rather than inherit whatever shell the machine running it has.
    ///
    /// `@concurrent` so the loop over the output stays off the caller's actor, which is the main
    /// actor, whatever the default isolation of a nonisolated async function becomes.
    @concurrent
    public static func run(
        _ command: String,
        cwd: String,
        variables: [String: String],
        shell: String = LoginShell.path(),
        onOutput: @escaping @MainActor @Sendable (ShellCommand.Output) -> Void
    ) async -> (ending: ProcessEnding, output: ShellCommand.Output) {
        // A PATH that arrives a moment late is a `command not found` for something the user has
        // installed. Usually free: the probe finished long before anybody typed a `!`.
        await LoginShellPath.ready()
        // The probe can take seconds, and Stop pressed during it must not start the command after.
        guard !Task.isCancelled else { return (.signalled(SIGTERM), ShellCommand.Output()) }

        let process = StreamingProcess(
            executable: shell,
            arguments: ["-c", command],
            cwd: cwd,
            environment: ProviderCredentialEnvironment.untrustedProcess(Shell.environment(extra: variables))
        )
        // A launch failure is reported through `lines`, which is read below. Started before the
        // cancellation handler is installed, so a cancel that has already happened signals a
        // process that exists.
        try? process.start()
        process.closeStdin()

        let output = await withTaskCancellationHandler {
            var output = ShellCommand.Output()
            var published: ContinuousClock.Instant?
            do {
                for try await line in process.lines {
                    output.append(line)
                    let now = ContinuousClock.now
                    if published.map({ $0.duration(to: now) >= publishInterval }) ?? true {
                        published = now
                        await onOutput(output)
                    }
                }
            } catch {
                output.append("\(error)")
            }
            return output
        } onCancel: {
            process.terminate()
            Task.detached {
                try? await Task.sleep(for: stopGrace)
                process.kill()
            }
        }
        return (await process.ending, output)
    }
}
