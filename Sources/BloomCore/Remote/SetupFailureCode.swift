import Foundation

/// The reasons a setup failure has a name, for `SetupRecord.failureCode`.
///
/// **One list, read by the machine and by every client.** The machine writes the code in brackets at
/// the end of its own sentence in the setup log (see `SandboxRefusal`), and the workspace record
/// carries it as a field so a client does not scan text for it. A code is added here first, and
/// nowhere else, because a client keying a button off one has to be able to find them all.
public enum SetupFailureCode: String, CaseIterable, Sendable {
    /// Setup asked for root. Only the first setup of a brand new machine has it, so the answer is a
    /// new machine rather than another run. See `MachineSandbox` and H1 in the review of
    /// 19 September 2026.
    case needsFreshMachine = "setup_needs_fresh_machine"
}
