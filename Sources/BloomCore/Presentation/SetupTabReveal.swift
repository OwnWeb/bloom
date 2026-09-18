import Foundation

/// Whether a Cloud workspace's setup tab should be brought forward.
///
/// Once per state, not once per event. The machine repeats its setup state on every event that
/// touches it, and a tab pulled to the front on each of them would take the strip from under
/// somebody reading a chat. What earns a reveal is a state worth watching: setup waiting to start,
/// running, or failed, which is the only way back from a setup that broke. Finished and skipped
/// are not: the setup log is still one tab away in the `+` for anybody who wants it.
///
/// A rule rather than a line in the session, because it was a tested rule inside `CloudTabs`, and
/// moving the tabs into the shared stores is not a reason for it to stop being one.
public struct SetupTabReveal: Sendable, Hashable {
    private var shown: Set<String> = []

    public init() {}

    /// Answers true the first time a state worth watching is seen, and false every time after.
    public mutating func shouldReveal(for state: String?) -> Bool {
        guard let state, Self.worthWatching.contains(state) else { return false }
        return shown.insert(state).inserted
    }

    static let worthWatching: Set<String> = ["pending", "running", "failed"]
}
