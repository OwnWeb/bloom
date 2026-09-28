import Foundation

/// Which workspaces have their subagent rows folded away in the sidebar.
///
/// **The default is open, and this names the exceptions.** It was stored the other way round, as
/// the set of workspaces somebody had opened, so a fan-out drew a count and nothing else until it
/// was clicked. The rows that count stands for are the one thing the pane says about what a
/// running turn is actually doing, and a reader who has to ask for them is a reader who does not
/// know there is anything to ask. Folding stays for the workspace that spawns a dozen, which is
/// why this is a set rather than nothing at all.
///
/// In the core rather than in `SidebarView`, because a default held in a view's `@State` is a
/// default nothing can test, and this one regressed once already.
public struct SubagentDisclosure: Equatable, Sendable {
    /// The workspaces folded away. Everything absent from it is open.
    private var folded: Set<WorkspaceID> = []

    public init() {}

    /// Whether this workspace's subagent rows are drawn.
    public func shows(_ id: WorkspaceID) -> Bool { !folded.contains(id) }

    /// Folds an open workspace, or opens a folded one.
    ///
    /// Nothing is tidied when a turn ends. A workspace whose subagents have gone contributes no
    /// rows either way, and forgetting that somebody had folded them would unfold the next
    /// fan-out in the same workspace under the pointer that folded the last one.
    public mutating func toggle(_ id: WorkspaceID) {
        if folded.remove(id) == nil { folded.insert(id) }
    }
}
