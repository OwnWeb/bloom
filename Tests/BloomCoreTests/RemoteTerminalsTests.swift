import Foundation
import Synchronization
import Testing
@testable import BloomCore

@Suite("RemoteTerminals", .scratchDirectory, .tags(.subprocess))
struct RemoteTerminalsTests {
    @Test func shutdownInvalidatesAndDrainsAnInFlightTerminalStart() async throws {
        let directory = TestScratch.unique("terminal-start-shutdown")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let process = StreamingProcess(executable: "/bin/sh", arguments: ["-c", "sleep 30"], cwd: directory)
        defer { process.kill() }
        let gate = RemoteTerminalStartGate()
        let cancelled = Mutex(false)
        let finished = Mutex(false)
        let daemon = RemoteTerminalDaemon(ownsDaemon: true, makeProcess: { _, _ in process }, run: { _, arguments, _ in
            if arguments.first == "show-options" {
                await withTaskCancellationHandler { await gate.wait() } onCancel: { cancelled.withLock { $0 = true } }
            }
            return ShellResult(status: 0, stdout: "", stderr: "")
        })
        let command = TmuxCommand(executable: "/unused/tmux", socketName: "fixture", configPath: directory + "/tmux.conf")
        let start = Task { () -> Bool in
            do {
                try await daemon.start(command: command, cwd: directory)
                return true
            } catch { return false }
        }
        await waitUntil("terminal readiness probe is pending") { await gate.entered }
        let shutdown = Task {
            await daemon.shutdown()
            finished.withLock { $0 = true }
        }
        await waitUntil("shutdown cancels the owned start") { cancelled.withLock { $0 } }
        #expect(!finished.withLock { $0 })
        await gate.release()
        let accepted = await start.value
        await shutdown.value
        #expect(!accepted)
        #expect(!process.isRunning)
        await #expect(throws: RemoteFailure.self) { try await daemon.start(command: command, cwd: directory) }
    }

    @Test func failedTerminalReadinessCleansUpItsOwnedProcess() async throws {
        let directory = TestScratch.unique("terminal-start-failure")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let process = StreamingProcess(executable: "/bin/sh", arguments: ["-c", "sleep 30"], cwd: directory)
        defer { process.kill() }
        let daemon = RemoteTerminalDaemon(ownsDaemon: true, makeProcess: { _, _ in process }, run: { _, _, _ in
            throw RemoteFailure(.unavailable, "Readiness failed")
        })
        let command = TmuxCommand(executable: "/unused/tmux", socketName: "fixture", configPath: directory + "/tmux.conf")
        await #expect(throws: RemoteFailure.self) { try await daemon.start(command: command, cwd: directory) }
        #expect(!process.isRunning)
        await daemon.shutdown()
    }

    @Test func closingAnAttachmentWaitsForAClientThatIgnoresTermination() async throws {
        let directory = TestScratch.unique("terminal-client-close")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let ready = directory + "/ready"
        let process = StreamingProcess(executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; printf ready > \"$1\"; while :; do sleep 1; done", "bloom-terminal-test", ready], cwd: directory)
        defer { process.kill() }
        let closed = Mutex(false)
        let attachment = RemoteTerminalAttachment(name: "fixture", session: "fixture", process: process) {
            closed.withLock { $0 = true }
        }
        await attachment.start(columns: 80, rows: 24)
        await waitUntil("fixture installed its TERM handler") { FileManager.default.fileExists(atPath: ready) }
        #expect(process.isRunning)
        await attachment.close()
        #expect(!process.isRunning)
        #expect(closed.withLock { $0 })
        var chunks = 0
        for await _ in attachment.output { chunks += 1 }
        #expect(chunks == 0)
    }

    @Test func aClientThatExitsFinishesItsOutput() async throws {
        let directory = TestScratch.unique("terminal-client-exit")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let process = StreamingProcess(executable: "/bin/sh",
            arguments: ["-c", "printf '%%output %%0 hello\\\\015\\\\012\\n'"], cwd: directory)
        let closed = Mutex(false)
        let attachment = RemoteTerminalAttachment(name: "fixture", session: "fixture", process: process) {
            closed.withLock { $0 = true }
        }
        await attachment.start(columns: 80, rows: 24)
        var received = Data()
        for await chunk in attachment.output { received.append(chunk) }
        #expect(received == Data("hello\r\n".utf8))
        await waitUntil("the attachment reported its end") { closed.withLock { $0 } }
    }

    @Test func controlOutputPreservesEscapeSequencesAndBinaryBytes() {
        var parser = TmuxControlOutput()
        let bytes = parser.take("%output %0 hello\\015\\012\\033[31m\\377")
        #expect(bytes == Data([104, 101, 108, 108, 111, 13, 10, 27, 91, 51, 49, 109, 255]))
        let begin = parser.take("%begin 123 1 0")
        #expect(begin == nil)
        let literal = parser.take("%output %0 this is captured text")
        #expect(literal == Data("%output %0 this is captured text\r\n".utf8))
        let end = parser.take("%end 123 1 0")
        #expect(end == nil)
    }

    @Test func reconnectRestoresScreenWithoutScrollingAndRestoresCursor() {
        var parser = TmuxControlOutput(restoringScreen: true)
        for number in 0...1 {
            _ = parser.take("%begin 123 \(number) 0")
            _ = parser.take("%end 123 \(number) 0")
        }
        _ = parser.take("%begin 123 2 0")
        _ = parser.take("previous output")
        _ = parser.take("$ ")
        let screen = parser.take("%end 123 2 0")
        #expect(screen == Data("\u{1b}[2J\u{1b}[Hprevious output\r\n$ ".utf8))
        _ = parser.take("%begin 123 3 0")
        _ = parser.take("2 1")
        let cursor = parser.take("%end 123 3 0")
        #expect(cursor == Data("\u{1b}[2;3H".utf8))
        let live = parser.take("%output %0 echo")
        #expect(live == Data("echo".utf8))
    }

    @Test func inputIsHexEncodedAndResizeIsBounded() {
        let command = TmuxControlOutput.input(Data(";kill-server\r".utf8), session: "owned")
        #expect(command == "send-keys -H -t =owned: 3b 6b 69 6c 6c 2d 73 65 72 76 65 72 0d")
        #expect(TmuxControlOutput.resize(columns: 0, rows: 24) == nil)
        #expect(TmuxControlOutput.resize(columns: 120, rows: 40) == "refresh-client -C 120,40")
        #expect(TmuxControlOutput.input(Data(repeating: 1, count: 16_385), session: "owned") == nil)
        #expect(TmuxControlOutput.input(Data(), session: "owned") == nil)
    }

    @Test func terminalNamesAndEnvironmentNamesAreRefusedBeforeTmuxRuns() async {
        let terminals = RemoteTerminals(workspaceID: WorkspaceID("fixture"), worktree: TestScratch.path("worktree"),
                                        databasePath: TestScratch.path("bloom.sqlite"))
        for name in ["", "has space", "semi;colon", String(repeating: "a", count: 65)] {
            await #expect(throws: RemoteFailure.self) { try await terminals.ensureSession(name: name) }
        }
        await #expect(throws: RemoteFailure.self) { try await terminals.ensureSession(name: "main", environment: ["A=B": "c"]) }
        await #expect(throws: RemoteFailure.self) { try await terminals.ensureSession(name: "main", environment: ["A B": "c"]) }
        await terminals.shutdown()
    }

    @Test func idleShellsDoNotBlockReplacementButRunningCommandsDo() {
        #expect(!RemoteTerminalDaemon.panesBlockMaintenance("0\tbash\t42\n1\tvim\t43", children: { _ in "" }))
        #expect(RemoteTerminalDaemon.panesBlockMaintenance("0\tbash\t42", children: { _ in "99 " }))
        #expect(RemoteTerminalDaemon.panesBlockMaintenance("0\tnode\t42", children: { _ in "" }))
        #expect(RemoteTerminalDaemon.panesBlockMaintenance("garbage", children: { _ in "" }))
    }

    @Test func aRunScriptRunsEvenWhenTheShellIsSlowToStart() async throws {
        guard Shell.which("tmux") != nil else { return }
        let repo = try await TempRepo()
        let databasePath = TestScratch.unique("terminal-run-script") + "/bloom.sqlite"
        try FileManager.default.createDirectory(atPath: (databasePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let configuration = ((databasePath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("tmux.conf")
        // A shell that takes two seconds to be ready, which is what a machine with a profile that
        // sources anything looks like. Keystrokes sent at creation fall into it and are lost.
        try (TmuxSessions.configuration(defaultShell: "/bin/sh") + "\nset -g default-command 'sleep 2; exec /bin/sh'\n")
            .write(toFile: configuration, atomically: true, encoding: .utf8)
        let terminals = RemoteTerminals(workspaceID: WorkspaceID("fixture"), worktree: repo.path, databasePath: databasePath)
        do {
            let marker = repo.path + "/ran.txt"
            let attachment = try await terminals.attach(name: "script", owner: "freek", runScript: "printf ran > \(marker)")
            await attachment.close()
            await waitUntil("the run script ran", within: .seconds(20)) {
                FileManager.default.fileExists(atPath: marker)
            }
            #expect(FileManager.default.fileExists(atPath: marker),
                    "tmux runs the command itself, so no keystroke can be sent before the shell is reading")
            // And the shell is still there afterwards, so somebody can read the output and carry on.
            let reattached = try await terminals.attach(name: "script", owner: "freek")
            await reattached.close()
        } catch {
            await terminals.shutdown()
            throw error
        }
        try? await terminals.closeAll()
        await terminals.shutdown()
    }

    @Test func aTerminalAndItsTmuxShellNeverReceiveProviderCredentials() async throws {
        guard Shell.which("tmux") != nil else { return }
        let repo = try await TempRepo()
        let databasePath = TestScratch.unique("terminal-provider-credentials") + "/bloom.sqlite"
        try FileManager.default.createDirectory(
            atPath: (databasePath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let terminals = RemoteTerminals(
            workspaceID: WorkspaceID("fixture"), worktree: repo.path, databasePath: databasePath
        )
        let output = repo.path + "/terminal-environment.txt"
        var environment = ["BLOOM_ALLOWED": "kept"]
        for name in ProviderCredentialEnvironment.prohibitedNames { environment[name] = "sentinel" }
        do {
            let attachment = try await terminals.attach(
                name: "scrubbed", environment: environment,
                runScript: "/usr/bin/env > \(output)"
            )
            await attachment.close()
            await waitUntil("the terminal wrote its environment") {
                (try? String(contentsOfFile: output, encoding: .utf8))?.contains("BLOOM_ALLOWED=kept") == true
            }
            let contents = try String(contentsOfFile: output, encoding: .utf8)
            #expect(contents.contains("BLOOM_ALLOWED=kept"))
            #expect(!contents.contains("sentinel"))
            for name in ProviderCredentialEnvironment.prohibitedNames {
                #expect(!contents.contains(name + "="))
            }
        } catch {
            await terminals.shutdown()
            throw error
        }
        try? await terminals.closeAll()
        await terminals.shutdown()
    }

    @Test func sharingEndsOnlyTheShellsHoldingPersonalCredentials() async throws {
        guard Shell.which("tmux") != nil else { return }
        let repo = try await TempRepo()
        let databasePath = TestScratch.unique("terminal-shared") + "/bloom.sqlite"
        try FileManager.default.createDirectory(atPath: (databasePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let terminals = RemoteTerminals(workspaceID: WorkspaceID("fixture"), worktree: repo.path, databasePath: databasePath)
        do {
            try await terminals.ensureSession(
                name: "personal", environment: ["PERSONAL_NAME": "mine"], owner: "freek",
                personal: [PersonalCredentials.environmentMark]
            )
            try await terminals.ensureSession(name: "team", environment: ["TEAM_NAME": "team"], owner: "seb")
            try await terminals.closeAll { !$0.isEmpty }
            let tmux = try #require(Shell.which("tmux"))
            let socket = TmuxSessions.socketName(databasePath: databasePath)
            func exists(_ name: String) async throws -> Bool {
                let session = TmuxSessions.sessionName(workspaceID: WorkspaceID("fixture"), paneID: name)
                return try await Shell.run(tmux, ["-L", socket, "has-session", "-t", "=" + session]).ok
            }
            #expect(try await !exists("personal"))
            #expect(try await exists("team"), "A shell on the team key stays")
        } catch {
            await terminals.shutdown()
            throw error
        }
        try? await terminals.closeAll()
        await terminals.shutdown()
    }

    @Test func disconnectReattachesTheSameShellWithoutReplayingInput() async throws {
        guard Shell.which("tmux") != nil else { return }
        let repo = try await TempRepo()
        let databasePath = TestScratch.unique("terminal-state") + "/bloom.sqlite"
        try FileManager.default.createDirectory(atPath: (databasePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let configuration = ((databasePath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("tmux.conf")
        try (TmuxSessions.configuration(defaultShell: "/bin/sh") + "\nset -g default-command /bin/sh\n").write(toFile: configuration, atomically: true, encoding: .utf8)
        let terminals = RemoteTerminals(workspaceID: WorkspaceID("fixture"), worktree: repo.path, databasePath: databasePath)
        do {
            let first = try await terminals.attach(name: "https", environment: ["BLOOM_TERMINAL_FIXTURE": "from-attach"], owner: "freek")
            // Somebody else attaching by name would act as the person who opened it.
            await #expect(throws: RemoteFailure.self) { try await terminals.attach(name: "https", owner: "seb") }
            await #expect(throws: RemoteFailure.self) { try await terminals.close(name: "https", requester: "seb") }
            await first.write(Data("printf \"first $BLOOM_TERMINAL_FIXTURE\\n\" >> stream.txt\r".utf8))
            await waitUntil("terminal writes the first command") { FileManager.default.fileExists(atPath: repo.path + "/stream.txt") }
            await first.close()
            let second = try await terminals.attach(name: "https", owner: "freek")
            // The screen comes back from tmux's copy, so the first command is on it before
            // anything new is typed.
            let restored = Task { () -> String in
                var text = ""
                for await chunk in second.output {
                    text += String(decoding: chunk, as: UTF8.self)
                    if text.contains("first $BLOOM_TERMINAL_FIXTURE") { return text }
                }
                return text
            }
            await second.write(Data("printf 'second\\n' >> stream.txt\r".utf8))
            await waitUntil("reconnected terminal executes once") {
                (try? String(contentsOfFile: repo.path + "/stream.txt", encoding: .utf8)) == "first from-attach\nsecond\n"
            }
            #expect(try String(contentsOfFile: repo.path + "/stream.txt", encoding: .utf8) == "first from-attach\nsecond\n")
            await second.close()
            // What came back is in the message, so a failure on a runner nobody can reach says why.
            let screen = await restored.value
            #expect(screen.contains("first $BLOOM_TERMINAL_FIXTURE"), "the reattached screen was: \(screen.debugDescription)")
            try await terminals.close(name: "https")
        } catch {
            await terminals.shutdown()
            throw error
        }
        await terminals.shutdown()
    }
}

private actor RemoteTerminalStartGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}
