/// The workspace columns worth keeping laid out for an immediate return.
///
/// A workspace switch used to hand one transcript table a different conversation. Even when both
/// conversations were already in memory, the table had to hide itself, replace its rows, restore
/// the reader's place and reveal again. Keeping the workspace being left beside the one being
/// entered gives the common back-and-forth switch two stable view identities instead.
///
/// Two is deliberate. It covers the comparison Seb reported without leaving every terminal,
/// browser and transcript visited during a day alive in the window.
public enum WorkspaceColumnCache {
    public static let capacity = 2

    /// Most recently visited first, with each workspace present at most once.
    public static func visiting(_ id: WorkspaceID, in current: [WorkspaceID]) -> [WorkspaceID] {
        var next = [id]
        next.append(contentsOf: current.lazy.filter { $0 != id }.prefix(capacity - 1))
        return next
    }

    public static func removing(_ id: WorkspaceID, from current: [WorkspaceID]) -> [WorkspaceID] {
        current.filter { $0 != id }
    }

    /// Keeps surviving view identities in their existing order while applying the membership of
    /// the recency list. A back-and-forth visit then changes no observed collection and SwiftUI
    /// does not move two large AppKit subtrees merely to reverse their order in a `ZStack`.
    public static func stableMembers(
        _ current: [WorkspaceID], from recency: [WorkspaceID]
    ) -> [WorkspaceID] {
        let wanted = Set(recency)
        var members = current.filter(wanted.contains)
        members.append(contentsOf: recency.filter { !members.contains($0) }.reversed())
        return members
    }
}
