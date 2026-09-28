import Testing
import Foundation
@testable import BloomCore

@Suite("Shell", .tags(.subprocess))
struct ShellTests {
    @Test("runs a command and captures stdout")
    func capturesStdout() async throws {
        let result = try await Shell.run("/bin/echo", ["hello", "world"])
        #expect(result.ok)
        #expect(result.trimmed == "hello world")
    }

    @Test("captures a non-zero exit status without throwing")
    func capturesFailure() async throws {
        let result = try await Shell.run("/bin/sh", ["-c", "echo oops >&2; exit 3"])
        #expect(result.status == 3)
        #expect(result.stderr.contains("oops"))
    }

    @Test("check throws on failure")
    func checkThrows() async throws {
        await #expect(throws: ShellError.self) {
            try await Shell.check("/bin/sh", ["-c", "exit 1"])
        }
    }

    @Test("passes stdin through")
    func passesStdin() async throws {
        let result = try await Shell.run("/bin/cat", [], stdin: "piped")
        #expect(result.trimmed == "piped")
    }

    @Test("honours the working directory")
    func honoursCwd() async throws {
        let result = try await Shell.run("/bin/pwd", [], cwd: "/tmp")
        #expect(result.trimmed.hasSuffix("tmp"))
    }

    @Test("splits output into lines")
    func splitsLines() async throws {
        let result = try await Shell.run("/bin/sh", ["-c", "printf 'a\\nb\\nc\\n'"])
        #expect(result.lines == ["a", "b", "c"])
    }

    @Test("finds executables on the augmented PATH")
    func resolvesExecutables() {
        #expect(Shell.which("git") != nil)
        #expect(Shell.which("definitely-not-a-real-binary-xyz") == nil)
    }

    /// The answer is remembered so that starting a subprocess is not a walk of the whole PATH, and
    /// asking twice therefore has to give the same answer rather than a remembered one that has
    /// drifted.
    @Test("a remembered path is the same path")
    func remembersWhatItFound() {
        #expect(Shell.which("git") == Shell.which("git"))
    }

    /// **A miss must not be remembered**, and asking twice is what a caller that depends on that
    /// does. "Not installed" is the one answer that legitimately changes while Bloom runs:
    /// `GitHubAvailability` re-asks so that signing in to `gh` from a terminal is noticed, and
    /// `WorkspaceNamer.isAvailable` is asked afresh on every create. A table that held onto nil
    /// would make installing a CLI something you have to relaunch the app to be told about.
    ///
    /// What this can check without installing anything on the owner's machine is that a name with
    /// no answer keeps having no answer rather than being poisoned by the first ask. The other
    /// half, that the second ask genuinely walks the PATH again, is held by the shape of the code:
    /// the table is only ever written on the branch that found something.
    @Test("a name with no answer is asked again rather than remembered as missing")
    func doesNotRememberAMiss() {
        let name = "bloom-not-installed-\(UUID().uuidString.prefix(8))"
        #expect(Shell.which(name) == nil)
        #expect(Shell.which(name) == nil)
    }

    @Test("captures large output without truncation")
    func capturesLargeOutput() async throws {
        let result = try await Shell.run("/bin/sh", ["-c", "seq 1 50000"])
        #expect(result.lines.count == 50_000)
        #expect(result.lines.last == "50000")
    }
}

@Suite("A launch that never returns", .tags(.subprocess))
struct CapturedProcessWatchdogTests {
    @Test("a launch that never answers is abandoned rather than waited on")
    func abandonsAHungLaunch() async throws {
        let before = Shell.abandonedLaunchCount
        let process = CapturedProcess(
            executable: "/usr/bin/true", arguments: [], cwd: nil, environment: [:], input: nil,
            timeout: .milliseconds(50), outputLimit: 1_024,
            // What a wedged `Process.run()` looks like from here: a worker thread that never
            // answers. Left running, which is the trade the grace is there to make rare.
            work: { Thread.sleep(forTimeInterval: 600); return ShellBytes(status: 0, stdout: Data(), stderr: Data()) },
            grace: .milliseconds(200)
        )
        let started = ContinuousClock.now
        // What the fix is for, in the three facts that cannot be moved by a busy machine: the call
        // came back, it came back as a timeout, and the abandonment was counted.
        await #expect(throws: ShellFailure.timedOut(command: "/usr/bin/true")) {
            _ = try await process.run()
        }
        #expect(Shell.abandonedLaunchCount == before + 1, "one leak is a fluke and fifty is a machine to replace")
        // A cap on infinity rather than a measurement: without the fix this call never returns, and
        // the stand-in would hold it for ten minutes. Asserting a tight duration is the fault this
        // repository has now fixed three times, and this test was the third.
        #expect(started.duration(to: .now) < .seconds(60))
    }

    @Test("a call with no deadline is left alone, because nobody here knows how long it should take")
    func noTimeoutMeansNoWatchdog() async throws {
        let result = try await CapturedProcess(
            executable: "/usr/bin/true", arguments: [], cwd: nil, environment: [:], input: nil,
            timeout: nil, outputLimit: 1_024,
            work: { ShellBytes(status: 0, stdout: Data("fine".utf8), stderr: Data()) }
        ).run()
        #expect(String(decoding: result.stdout, as: UTF8.self) == "fine")
    }
}

/// A number alone cannot say how a process ended, and reading one as the other cost a morning.
@Suite("How a process ended")
struct ProcessEndingTests {
    @Test("a signal is named rather than reported as an exit code")
    func signalsAreNamed() {
        // The one that started this: a setup script killed by SIGPIPE, reported as "status 13".
        #expect(ProcessEnding.signalled(SIGPIPE).sentence.contains("SIGPIPE"))
        #expect(ProcessEnding.signalled(SIGPIPE).sentence.contains("stopped reading"),
                "and why, because SIGPIPE on its own says nothing about whose fault it is")
        #expect(ProcessEnding.signalled(SIGTERM).sentence.contains("Bloom"), "a stop Bloom asked for says so")
        #expect(ProcessEnding.signalled(SIGSEGV).sentence.contains("SIGSEGV"))
        #expect(ProcessEnding.signalled(64).sentence.contains("64"), "an unnamed signal keeps its number")

        // An exit code still reads as one, because most of them are.
        #expect(ProcessEnding.exited(13).sentence == "exited with status 13")
        #expect(ProcessEnding.exited(13).sentence != ProcessEnding.signalled(13).sentence,
                "the two thirteens are different events and must not read alike")
    }

    @Test("only a clean exit is a success")
    func successIsExitZeroAlone() {
        #expect(ProcessEnding.exited(0).isSuccess)
        #expect(!ProcessEnding.exited(1).isSuccess)
        // A process killed by a signal has not succeeded, whatever the number happens to be.
        #expect(!ProcessEnding.signalled(0).isSuccess)
        #expect(!ProcessEnding.signalled(SIGPIPE).isSuccess)
    }
}

#if os(Linux)
/// The arithmetic behind `WIFSIGNALED` and its siblings, which Swift cannot import because they are
/// C macros, written out and checked against the values the kernel actually produces.
@Suite("Reading a wait status")
struct WaitStatusTests {
    @Test("an ordinary exit carries its code in the second byte")
    func exitCodes() {
        #expect(!StreamingProcess.wasSignalled(0))
        #expect(StreamingProcess.exitCode(0) == 0)
        // 13 << 8: the shape a script exiting 13 leaves, which is not the same 13 as SIGPIPE.
        #expect(StreamingProcess.exitCode(13 << 8) == 13)
        #expect(!StreamingProcess.wasSignalled(13 << 8))
    }

    @Test("a signalled child carries the signal in the low seven bits")
    func signals() {
        #expect(StreamingProcess.wasSignalled(13), "SIGPIPE, the one that started all this")
        #expect(StreamingProcess.terminatingSignal(13) == 13)
        #expect(StreamingProcess.wasSignalled(15) && StreamingProcess.terminatingSignal(15) == 15)
        // 0x7f is stopped rather than terminated, and must not read as a signal death.
        #expect(!StreamingProcess.wasSignalled(0x7F))
    }
}
#endif
