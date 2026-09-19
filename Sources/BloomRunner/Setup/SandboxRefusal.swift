import Foundation

/// Reading a setup failure that is really "this needed root, and this run does not have it".
///
/// **The one change people meet first.** Setup gets root on a fresh machine's first run and never
/// again (see `MachineSetup.runScript`), so a resume or a rerun that installs a system package now
/// fails where it used to work. A bare "exit 1" would leave somebody reading a log for the reason,
/// so the log says which line was refused, why, and what to do instead.
enum SandboxRefusal {
    /// What the code is called on the wire and in runbloom.app's own screens, so the web can key its
    /// "Replace the machine" button off it rather than off the words.
    static let code = "setup_needs_fresh_machine"

    /// Lines that mean root was refused rather than the project's own failure. sudo's refusal, and
    /// the two shapes apt and dpkg use when they cannot take their locks.
    static let markers = [
        "sudo: a password is required",
        "sudo: no tty present",
        "sudo: unable to",
        "are you root?",
        "dpkg: error: requested operation requires superuser privilege",
        "Could not open lock file /var/lib/dpkg/lock",
        "Permission denied (os error 13)",
    ]

    /// The sentence for the setup log, or nil when the failure was not about permission at all.
    ///
    /// `lines` is the step's output as it was streamed. The most recent command before the refusal
    /// is quoted when the script traced one (`set -x` writes `+ sudo apt-get …`), because naming it
    /// is the difference between advice and a platitude.
    static func advice(lines: [String], user: String) -> String? {
        guard let refusal = lines.last(where: { line in markers.contains { line.localizedCaseInsensitiveContains($0) } }) else {
            return nil
        }
        let attempted = command(before: refusal, in: lines)
        let named = attempted.map { "`\($0)` was refused" } ?? "A command in this script asked for root and was refused"
        return "[bloom] \(named). Setup runs as \(user), which cannot install system packages: only the first setup of a "
            + "brand new machine gets root, and this workspace has been worked in since. Create the workspace's machine "
            + "again with Replace the machine to run setup with root, or move what needs root into the project's "
            + "container image. (\(code))"
    }

    /// The traced command nearest above the refusal, without the tracing prefix. Only a line that
    /// actually asked for root, because quoting the wrong line is worse than quoting none.
    private static func command(before refusal: String, in lines: [String]) -> String? {
        guard let index = lines.lastIndex(of: refusal) else { return nil }
        for line in lines[..<index].reversed() {
            let text = line.trimmingCharacters(in: .whitespaces)
            let traced = text.hasPrefix("+ ") ? String(text.dropFirst(2)) : text
            guard traced.contains("sudo") || traced.contains("apt-get") || traced.contains("apt ") || traced.contains("dpkg") else { continue }
            return String(traced.prefix(200))
        }
        return nil
    }
}
