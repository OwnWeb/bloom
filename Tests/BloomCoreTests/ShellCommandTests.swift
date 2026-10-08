import Foundation
import Testing
@testable import BloomCore

@Suite("Running a `!` command from the composer", .timeLimit(.minutes(1)))
struct ShellCommandTests {
    // MARK: - Which drafts are commands

    @Test("A draft starting with `!` is the command after it")
    func readsCommand() {
        #expect(ShellCommand.command(in: "!npm test") == "npm test")
        #expect(ShellCommand.command(in: "! git status \n") == "git status")
    }

    @Test("A `!` anywhere but first, or with nothing after it, is a message")
    func leavesMessagesAlone() {
        #expect(ShellCommand.command(in: "Ship it!") == nil)
        #expect(ShellCommand.command(in: " !ls") == nil)
        #expect(ShellCommand.command(in: "!") == nil)
        #expect(ShellCommand.command(in: "!   ") == nil)
    }

    @Test("A `!` typed into an empty composer gets its space, and nothing else does")
    func spacesTheBang() {
        #expect(ShellCommand.autoSpaced(from: "", to: "!") == "! ")
        #expect(ShellCommand.autoSpaced(from: "", to: "!ls") == nil)
        #expect(ShellCommand.autoSpaced(from: "! ", to: "!") == nil)
        #expect(ShellCommand.autoSpaced(from: "Hi", to: "Hi!") == nil)
    }

    // MARK: - What is kept of the output

    @Test("Short output is kept whole")
    func keepsShortOutput() {
        var output = ShellCommand.Output()
        output.append("one")
        output.append("two")
        #expect(output.text == "one\ntwo")
        #expect(output.recent(1) == ["two"])
    }

    @Test("Long output keeps both ends and says how much went from the middle")
    func keepsBothEnds() {
        var output = ShellCommand.Output()
        let total = ShellCommand.Output.headLines + ShellCommand.Output.tailLines + 5
        for index in 1...total { output.append("line \(index)") }

        #expect(output.droppedLines == 5)
        #expect(output.head.first == "line 1")
        #expect(output.tail.last == "line \(total)")
        #expect(output.text.contains("[5 lines of this output are not shown]"))
        #expect(!output.text.contains("line \(ShellCommand.Output.headLines + 1)\n"))
    }

    @Test("A progress bar keeps its last redraw, without colour")
    func cleansLines() {
        #expect(ShellCommand.Output.clean("10%\r50%\r100%") == "100%")
        #expect(ShellCommand.Output.clean("\u{1B}[31mfailed\u{1B}[0m") == "failed")
    }

    @Test("A huge line is cut, and the whole message stays under the cap")
    func capsSize() {
        var output = ShellCommand.Output()
        let huge = String(repeating: "x", count: ShellCommand.Output.maxLineCharacters * 3)
        for _ in 0..<200 { output.append(huge) }

        #expect(output.head[0].hasSuffix("[the rest of this line is not shown]"))
        #expect(output.text.hasPrefix("[the start of this output is not shown]"))
        #expect(output.text.count <= ShellCommand.Output.maxCharacters + 100)
    }

    // MARK: - What the agent is told

    @Test("The message names the command, what it printed and how it ended, in Claude Code's tags")
    func composesMessage() {
        var output = ShellCommand.Output()
        output.append("1 failing")
        let message = ShellCommand.message(command: "npm test", output: output, ending: .exited(1))

        #expect(message == "<bash-input>npm test</bash-input>\n<bash-stdout>1 failing</bash-stdout>\n"
            + "<bash-status>exited with status 1</bash-status>")
    }

    @Test("A sent command is read back whole, so the transcript can draw it as one")
    func readsBack() {
        var output = ShellCommand.Output()
        output.append("printed </bash-stdout>\n<bash-status> itself")
        let message = ShellCommand.message(command: "cat odd.txt", output: output, ending: .exited(0))

        let sent = ShellCommand.split(message)
        #expect(sent?.command == "cat odd.txt")
        #expect(sent?.output == "printed </bash-stdout>\n<bash-status> itself")
        #expect(sent?.succeeded == true)
    }

    @Test("A command that printed nothing and failed reads back as both")
    func readsBackEmptyFailure() {
        let message = ShellCommand.message(command: "false", output: .init(), ending: .exited(1))
        let sent = ShellCommand.split(message)

        #expect(sent?.output == "")
        #expect(sent?.status == "exited with status 1")
        #expect(sent?.succeeded == false)
    }

    @Test("Anything not written by `message` is drawn as the text it is")
    func leavesOtherTurnsAlone() {
        #expect(ShellCommand.split("Run npm test please") == nil)
        #expect(ShellCommand.split("<bash-input>ls</bash-input>") == nil)
        #expect(ShellCommand.split(
            "<bash-input>ls</bash-input>\n<bash-stdout>a</bash-stdout>\n<bash-status>ok</bash-status> and more"
        ) == nil)
    }

    @Test("Elsewhere a sent command reads as what was typed: in a summary, and under Up")
    func readsAsTyped() {
        let message = ShellCommand.message(command: "npm test", output: .init(), ending: .exited(0))

        #expect(UserTurnPrompt.summary(of: message) == "! npm test")
        #expect(PromptRecall.prompts(from: [message]) == ["! npm test"])
        #expect(ShellCommand.command(in: "! npm test") == "npm test")
    }

    @Test("A queued command is not offered for editing, which would hand back its tags")
    func isNotPlainText() {
        let message = ShellCommand.message(command: "ls", output: .init(), ending: .exited(0))
        #expect(!PendingMessageDiscard.isPlainText(message))
    }

    @Test("A command over several lines comes back whole")
    func readsBackMultiline() {
        let message = ShellCommand.message(command: "echo a\necho b", output: .init(), ending: .exited(0))
        #expect(ShellCommand.split(message)?.command == "echo a\necho b")
    }

    // MARK: - Running

    @Test("Each stream keeps its own order, both arrive, and the status is the command's own")
    func runs() async {
        // Order is only promised within a stream: stdout and stderr are two pipes, read by two
        // handlers, and which of them is drained first is the scheduler's business.
        let result = await Self.run("echo one; echo two; echo three >&2; exit 3")
        let lines = result.output.head

        #expect(lines.filter { $0 != "three" } == ["one", "two"])
        #expect(Set(lines) == ["one", "two", "three"])
        #expect(result.ending == .exited(3))
    }

    @Test("A command reading stdin gets end of file rather than waiting for ever")
    func closesStdin() async {
        let result = await Self.run("cat; echo done")

        #expect(result.output.head == ["done"])
        #expect(result.ending == .exited(0))
    }

    @Test("The workspace's variables arrive and provider credentials do not")
    func crossesCredentialBoundary() async throws {
        let credential = try #require(ProviderCredentialEnvironment.prohibitedNames.min())
        let result = await Self.run(
            "echo \"$BLOOM_SHELL_TEST\"; echo \"${\(credential):-absent}\"",
            variables: ["BLOOM_SHELL_TEST": "workspace", credential: "secret"]
        )

        #expect(result.output.head == ["workspace", "absent"])
    }

    @Test("Cancelling stops the command, and the first line is shown without waiting for a second")
    func stops() async {
        let (started, signal) = AsyncStream.makeStream(of: Void.self)
        let run = Task {
            await ShellCommandRun.run(
                "echo started; exec sleep 600", cwd: Self.directory, variables: [:], shell: "/bin/sh"
            ) { _ in signal.yield() }
        }
        for await _ in started { break }
        run.cancel()

        #expect(await run.value.ending == .signalled(SIGTERM))
    }

    @Test("Cancelled before it starts, nothing is run")
    func stopsBeforeStarting() async throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "bloom-shell-\(UUID())").path
        let run = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await Self.run("touch '\(marker)'")
        }

        #expect(await run.value.ending == .signalled(SIGTERM))
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    private static let directory = FileManager.default.temporaryDirectory.path

    /// `/bin/sh` rather than the user's shell, so a suite run under fish, or a zsh whose
    /// `.zshenv` exports something, asserts the same thing as anywhere else.
    private static func run(
        _ command: String, variables: [String: String] = [:]
    ) async -> (ending: ProcessEnding, output: ShellCommand.Output) {
        await ShellCommandRun.run(command, cwd: directory, variables: variables, shell: "/bin/sh") { _ in }
    }
}
