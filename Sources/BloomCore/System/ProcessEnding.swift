#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// How a process ended, in the only two ways it can, and what to say about each.
///
/// **A number alone cannot be read.** Foundation on Linux reports a signalled process by putting
/// the signal number in `terminationStatus` rather than 128 plus it, so 13 is either a program
/// saying 13 or a program killed by `SIGPIPE`, and nothing in the number tells them apart. A Cloud
/// workspace's `resume` script was reported as "exited with status 13" when it had been killed by
/// SIGPIPE as the server shut down under it, and the person reading that took it for the script's
/// own verdict and rebuilt by hand what setup should have done.
public enum ProcessEnding: Sendable, Hashable {
    case exited(Int32)
    case signalled(Int32)

    public var isSuccess: Bool {
        if case .exited(0) = self { return true }
        return false
    }

    /// What to say about it, for a person reading a setup log rather than a debugger.
    ///
    /// Two signals get a sentence of their own because they are the two that arrive here and both
    /// are about Bloom rather than about the script: `SIGTERM` is Bloom stopping it, and `SIGPIPE`
    /// means it wrote output after Bloom had stopped reading, which is what a shutdown mid-step
    /// looks like from the script's side.
    public var sentence: String {
        switch self {
        case .exited(let status): "exited with status \(status)"
        case .signalled(SIGTERM): "was stopped by Bloom (SIGTERM)"
        case .signalled(SIGPIPE):
            "was killed by SIGPIPE, which means it wrote output after Bloom stopped reading it: "
                + "that is what a server shutting down mid-step looks like from the script's side"
        case .signalled(let signal): "was killed by \(Self.name(of: signal))"
        }
    }

    /// The name rather than the number, because `SIGSEGV` says what to do next and 11 does not.
    /// Only the signals that can reach a script Bloom runs are named; anything else keeps its
    /// number, which is still better than being read as an exit code.
    public static func name(of signal: Int32) -> String {
        switch signal {
        case SIGHUP: "SIGHUP"
        case SIGINT: "SIGINT"
        case SIGQUIT: "SIGQUIT"
        case SIGILL: "SIGILL"
        case SIGABRT: "SIGABRT"
        case SIGFPE: "SIGFPE"
        case SIGKILL: "SIGKILL"
        case SIGBUS: "SIGBUS"
        case SIGSEGV: "SIGSEGV"
        case SIGPIPE: "SIGPIPE"
        case SIGTERM: "SIGTERM"
        case SIGXCPU: "SIGXCPU"
        case SIGXFSZ: "SIGXFSZ"
        default: "signal \(signal)"
        }
    }
}
