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

    // MARK: - Running

    @Test("Lines arrive in order, stderr included, and the status is the command's own")
    @MainActor
    func runs() async {
        let collected = Collected()
        let ending = await ShellCommandRun.run(
            "echo one; echo two >&2; exit 3", cwd: Self.directory, variables: [:]
        ) { collected.lines.append($0) }

        #expect(collected.lines == ["one", "two"])
        #expect(ending == .exited(3))
    }

    @Test("A command reading stdin gets end of file rather than waiting for ever")
    @MainActor
    func closesStdin() async {
        let collected = Collected()
        let ending = await ShellCommandRun.run("cat; echo done", cwd: Self.directory, variables: [:]) {
            collected.lines.append($0)
        }

        #expect(collected.lines == ["done"])
        #expect(ending == .exited(0))
    }

    @Test("The workspace's variables arrive and provider credentials do not")
    @MainActor
    func crossesCredentialBoundary() async throws {
        let credential = try #require(ProviderCredentialEnvironment.prohibitedNames.min())
        let collected = Collected()
        _ = await ShellCommandRun.run(
            "echo \"$BLOOM_SHELL_TEST\"; echo \"${\(credential):-absent}\"",
            cwd: Self.directory,
            variables: ["BLOOM_SHELL_TEST": "workspace", credential: "secret"]
        ) { collected.lines.append($0) }

        #expect(collected.lines == ["workspace", "absent"])
    }

    @Test("Cancelling stops the command")
    @MainActor
    func stops() async {
        let (started, signal) = AsyncStream.makeStream(of: Void.self)
        let run = Task { @MainActor in
            await ShellCommandRun.run("echo started; exec sleep 600", cwd: Self.directory, variables: [:]) { _ in
                signal.yield()
            }
        }
        for await _ in started { break }
        run.cancel()

        #expect(await run.value == .signalled(SIGTERM))
    }

    private static let directory = FileManager.default.temporaryDirectory.path

    @MainActor
    private final class Collected {
        var lines: [String] = []
    }
}
