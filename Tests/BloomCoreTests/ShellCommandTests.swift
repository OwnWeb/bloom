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

    @Test("The message names the command, how it ended and what it printed")
    func composesMessage() {
        var output = ShellCommand.Output()
        output.append("1 failing")
        let message = ShellCommand.message(command: "npm test", output: output, ending: .exited(1))

        #expect(message == "I ran this in the worktree:\n\n```sh\nnpm test\n```\n\n"
            + "It exited with status 1. Its output:\n\n```\n1 failing\n```")
    }

    @Test("A command that printed nothing says so rather than showing an empty block")
    func saysNothingPrinted() {
        let message = ShellCommand.message(command: "true", output: .init(), ending: .exited(0))
        #expect(message.hasSuffix("It exited with status 0 and printed nothing."))
    }

    @Test("Output holding a fence cannot close the message's own")
    func outgrowsFences() {
        var output = ShellCommand.Output()
        output.append("````")
        let message = ShellCommand.message(command: "cat README.md", output: output, ending: .exited(0))
        #expect(message.contains("`````sh\n"))
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
