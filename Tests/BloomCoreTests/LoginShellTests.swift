import Testing
import Foundation
@testable import BloomCore

/// Which shell a Bloom terminal starts, and what it calls it.
///
/// Two places decided this independently and identically: the pty `TerminalView` launches, and
/// the tmux configuration `TerminalPersistence` writes. Neither knew about the other, so the day
/// one learned something the other did not, the difference would be invisible until somebody's
/// `.zprofile` stopped running in one of Bloom's two terminals and not the other.
@Suite("Which shell a terminal starts")
struct LoginShellTests {
    private func path(_ shell: String?, executable: Set<String> = ["/bin/zsh", "/opt/homebrew/bin/fish"]) -> String {
        LoginShell.path(
            environment: shell.map { ["SHELL": $0] } ?? [:],
            isExecutable: executable.contains
        )
    }

    @Test("the user's own shell is used when it is really there")
    func theUsersShellWins() {
        #expect(path("/opt/homebrew/bin/fish") == "/opt/homebrew/bin/fish")
    }

    /// A stale `SHELL` pointing at a removed homebrew shell is the ordinary way this goes wrong.
    @Test("a shell that is not on disk falls back")
    func aMissingShellFallsBack() {
        #expect(path("/opt/homebrew/bin/nushell") == LoginShell.fallback)
        #expect(path(nil) == LoginShell.fallback)
    }

    /// Empty is not a path, and `?? "/bin/zsh"` only catches a missing key.
    @Test("an empty SHELL is not treated as a shell")
    func anEmptyShellIsNotAPath() {
        #expect(path("") == LoginShell.fallback)
    }

    /// The leading dash is the whole convention: it is what makes bash read `.bash_profile` and
    /// zsh read `.zprofile`, so a terminal that gets it wrong is one where the user's own setup
    /// silently did not run.
    @Test("argv zero is the shell's name with a dash in front")
    func argumentZeroCarriesTheDash() {
        #expect(LoginShell.argumentZero(for: "/bin/zsh") == "-zsh")
        #expect(LoginShell.argumentZero(for: "/opt/homebrew/bin/fish") == "-fish")
    }

    /// The bug this pair existed to close. `TerminalView` tested the path, fell back, and then
    /// named the shell from the value it had just rejected, so a machine with a stale `SHELL`
    /// would run `/bin/zsh` under the name `-fish` and read the wrong profile.
    @Test("a rejected shell does not lend its name to the one that runs")
    func theNameFollowsTheShellThatRuns() {
        let resolved = path("/opt/homebrew/bin/nushell")
        #expect(resolved == LoginShell.fallback)
        #expect(LoginShell.argumentZero(for: resolved) == "-zsh")
        #expect(LoginShell.argumentZero(for: resolved) != "-nushell")
    }
}

/// Which shell a terminal on a Cloud workspace's machine starts, where `SHELL` is a service's
/// rather than a person's.
@Suite("Which shell a machine's terminal starts")
struct MachineLoginShellTests {
    private func machine(passwd: String?, shell: String?, executable: Set<String> = ["/bin/bash", "/bin/sh", "/usr/bin/zsh"]) -> String {
        LoginShell.machinePath(
            passwd: { passwd },
            environment: shell.map { ["SHELL": $0] } ?? [:],
            isExecutable: executable.contains
        )
    }

    /// The exact shape that produced a bare `$` on a Cloud workspace: the account's shell is bash
    /// and the service that started the tmux server was handed `SHELL=/bin/sh`.
    @Test("the account's shell beats the service's environment")
    func passwdBeatsTheEnvironment() {
        #expect(machine(passwd: "/bin/bash", shell: "/bin/sh") == "/bin/bash")
    }

    @Test("a passwd entry that is not on disk falls back to the environment, then to the fallback")
    func fallsBackWhenPasswdIsWrong() {
        #expect(machine(passwd: "/usr/bin/nushell", shell: "/usr/bin/zsh") == "/usr/bin/zsh")
        #expect(machine(passwd: nil, shell: nil) == LoginShell.fallback)
        #expect(machine(passwd: "", shell: "/bin/bash") == "/bin/bash", "empty is not a path here either")
    }

    /// An unknown flag leaves somebody with no shell at all, which is worse than a plain one.
    @Test("the login flag is passed only to shells that have one")
    func onlyShellsThatTakeItGetTheFlag() {
        #expect(LoginShell.loginArguments(for: "/bin/bash") == ["-l"])
        #expect(LoginShell.loginArguments(for: "/usr/bin/zsh") == ["-l"])
        #expect(LoginShell.loginArguments(for: "/bin/sh").isEmpty, "sh on a Sprite is dash, which has no -l")
    }
}
