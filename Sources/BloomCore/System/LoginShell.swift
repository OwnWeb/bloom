#if os(Linux)
import Glibc
#else
import Darwin
#endif
import Foundation

/// Which shell Bloom starts, and what it calls it.
///
/// Two places decided this independently and identically: the pty `TerminalView` launches, and
/// the tmux configuration `TerminalPersistence` writes. Each read `SHELL`, each fell back to
/// `/bin/zsh` twice over, and neither knew about the other. The day one of them learns something
/// the other does not, an empty `SHELL`, a login flag, a shell that is a symlink, the difference
/// is invisible until somebody's `.zprofile` stops running in one of the two terminals Bloom
/// offers and not the other.
///
/// **This has now happened three times, and the third was on a Cloud workspace's machine**, where
/// a run script's pane ended in a login shell and a plain pane ran whatever the service manager
/// had put in `SHELL`. The type existed, this comment existed, and neither prevented it, because a
/// new context does not look like the old one: somebody reaching for "which shell should a machine
/// start" does not recognise it as the question this file already answers. If you are about to
/// write that decision somewhere else, it belongs here, whatever is different about your case.
///
/// The environment and the executable test are parameters so this can be asserted on without the
/// answer depending on the machine running the suite.
public enum LoginShell {
    /// Where it lands when `SHELL` says nothing usable. macOS's own default since Catalina, and
    /// the one shell that is on every supported system.
    #if os(Linux)
    // A Linux image is not promised zsh, and the Sprite image does not carry it.
    public static let fallback = "/bin/sh"
    #else
    public static let fallback = "/bin/zsh"
    #endif

    /// The shell to run.
    ///
    /// Empty is not a path. `SHELL=""` used to survive the `??`, which only catches a missing
    /// key, and then fail the executable test, so the shell was right and the name derived from
    /// it was not: see `argumentZero(for:)` and the bug it fixes.
    public static func path(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String {
        guard let named = environment["SHELL"], !named.isEmpty, isExecutable(named) else {
            return fallback
        }
        return named
    }

    /// The shell for a terminal on a Cloud workspace's machine, where `SHELL` is nobody's choice.
    ///
    /// **`path(environment:)` above trusts `SHELL` because on a Mac a person set it.** On a machine
    /// the tmux server is started by Bloom Runner, which is started by the provider's service
    /// manager, and a service's environment carries `SHELL=/bin/sh`. That is not a preference, it
    /// is a default nobody chose, and it is why a Cloud terminal ran dash: a bare `$`, no profile
    /// read, and a person's notes about their own machine made wrong. Worse, the two terminals
    /// disagreed, because a run script's pane ended with `exec "$SHELL" -l` and a plain pane took
    /// tmux's default.
    ///
    /// So here the passwd entry is asked first, since it is what the account's shell actually is
    /// and no service manager can overwrite it, and `SHELL` is only the fallback.
    public static func machinePath(
        passwd: () -> String? = passwdShell,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String {
        if let shell = passwd(), !shell.isEmpty, isExecutable(shell) { return shell }
        return path(environment: environment, isExecutable: isExecutable)
    }

    /// The shell field of this user's passwd entry, which is what `SHELL` is supposed to hold.
    public static func passwdShell() -> String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        let path = String(cString: shell)
        return path.isEmpty ? nil : path
    }

    /// How to make a shell read a profile when something has to `exec` it rather than let tmux
    /// start it: `-l` for the shells that take one, and nothing for the ones that do not.
    ///
    /// **Where tmux starts the shell there is nothing to pass**: with `default-command` empty it
    /// makes a login shell of the `default-shell` itself, by the `argumentZero` convention below,
    /// which is why a plain terminal is created with no command at all. This is for the run script
    /// path, which has a command and must hand the shell back afterwards.
    ///
    /// `sh` on a Sprite is dash, which has no `-l`, and an unknown flag leaves somebody with no
    /// shell rather than a plain one.
    public static func loginArguments(for path: String) -> [String] {
        ["bash", "zsh", "ksh", "ksh93", "mksh", "fish"].contains((path as NSString).lastPathComponent) ? ["-l"] : []
    }

    /// `argv[0]` for a login shell, which is its name with a dash in front. That leading dash is
    /// the whole convention: it is what makes bash read `.bash_profile` and zsh read `.zprofile`,
    /// so a terminal that gets it wrong is one where the user's own setup silently did not run.
    ///
    /// Taken from the resolved path rather than from `SHELL` directly, which is the bug this
    /// exists to close. `TerminalView` tested the path for executability and fell back, then
    /// named the shell from the value it had just rejected: a machine with a stale `SHELL`
    /// pointing at a removed homebrew fish would run `/bin/zsh` under the name `-fish`.
    public static func argumentZero(for path: String) -> String {
        "-" + (path as NSString).lastPathComponent
    }
}
