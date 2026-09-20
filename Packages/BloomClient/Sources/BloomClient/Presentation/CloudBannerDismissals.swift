import Foundation

/// Which banners a reader has put away, per Cloud workspace.
///
/// A setup that failed stays failed until somebody fixes the project's script, so its banner would
/// otherwise sit over every visit to that workspace for as long as it exists. Putting it away is
/// remembered, and the state itself is still in the Setup tab, which the banner says.
///
/// Per workspace rather than per app: two workspaces failing setup are two different problems, and
/// hiding one must not hide the other. The keys carry when the state was reached, so a workspace
/// that fails again shows the new failure rather than staying quiet behind an old dismissal.
public struct CloudBannerDismissals: Sendable, Hashable {
    private var dismissed: [String: Set<String>]

    public init(_ dismissed: [String: Set<String>] = [:]) {
        self.dismissed = dismissed
    }

    public func isDismissed(_ banner: CloudConnectionBanner, workspaceID: String) -> Bool {
        guard let key = banner.dismissalKey else { return false }
        return dismissed[workspaceID]?.contains(key) == true
    }

    /// Nothing happens for a banner that cannot be dismissed, so a caller may offer the close
    /// button on whatever it likes and only the ones that mean it are remembered.
    public mutating func dismiss(_ banner: CloudConnectionBanner, workspaceID: String) {
        guard let key = banner.dismissalKey else { return }
        dismissed[workspaceID, default: []].insert(key)
    }

    /// Everything remembered for a workspace, which is what archiving one throws away.
    public mutating func forget(workspaceID: String) {
        dismissed.removeValue(forKey: workspaceID)
    }

    /// The whole thing as it is stored, which is a dictionary of arrays because a `Set` is not a
    /// property list value.
    public var stored: [String: [String]] {
        dismissed.mapValues { $0.sorted() }
    }

    public init(stored: [String: [String]]) {
        dismissed = stored.mapValues(Set.init)
    }
}
