import Foundation

/// The notifications a Mac posts about Cloud workspaces, derived from two readings of runbloom.app's
/// list.
///
/// Phase 1 has no push notifications, so the list the sidebar already polls is the only signal:
/// a workspace moving into `waiting_for_input`, from `running` to `idle`, or into `setup_failed`
/// since the last poll. The rules that keep that from being noise:
///
/// - **The first reading says nothing.** Launching Bloom with three workspaces waiting is not
///   three things that just happened.
/// - **A workspace seen for the first time says nothing either**, unless it already failed setup
///   having been created from this Mac, which the caller says by listing it in `watching`.
/// - **Only workspaces the reader belongs to**, because a team admin can see private workspaces
///   exist without being able to open them.
/// - **A turn ending that the reader started or answered while looking at it** is filtered by the
///   caller, which knows what is on screen; this type knows only the list.
public enum CloudWorkspaceNotices {
    public enum Kind: String, Sendable, Hashable {
        case needsInput
        case finished
        case setupFailed
    }

    public struct Notice: Sendable, Hashable {
        public var kind: Kind
        public var workspaceID: String
        public var name: String
        /// The machine's last message, when it had one worth quoting.
        public var detail: String

        public init(kind: Kind, workspaceID: String, name: String, detail: String) {
            self.kind = kind
            self.workspaceID = workspaceID
            self.name = name
            self.detail = detail
        }
    }

    /// - Parameters:
    ///   - previous: the last reading, or nil when there has not been one.
    ///   - watching: workspaces created from this Mac that have not been read yet, so a setup that
    ///     fails before the first poll after creating is still reported.
    public static func between(previous: [CloudWorkspaceItem]?, current: [CloudWorkspaceItem], watching: Set<String> = []) -> [Notice] {
        guard let previous else { return [] }
        let before = Dictionary(previous.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        return current.compactMap { item in
            guard item.isMember else { return nil }
            let was = before[item.id]
            guard was != nil || watching.contains(item.id) else { return nil }
            guard was != item.state else { return nil }
            let detail = item.summary?.lastMessage?.excerpt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            switch item.state {
            case "waiting_for_input":
                return Notice(kind: .needsInput, workspaceID: item.id, name: item.displayName, detail: detail)
            case "idle" where was == "running":
                return Notice(kind: .finished, workspaceID: item.id, name: item.displayName, detail: detail)
            case "setup_failed":
                return Notice(kind: .setupFailed, workspaceID: item.id, name: item.displayName, detail: "")
            default:
                return nil
            }
        }
    }
}
