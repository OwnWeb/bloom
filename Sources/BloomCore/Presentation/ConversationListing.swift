import Foundation

/// Saved presentation choices for a conversation with no project.
public enum ConversationListing {
    public static func pinnedKey(_ id: SessionID) -> String {
        "conversation.pinned.\(id.rawValue)"
    }

    public static func colourKey(_ id: SessionID) -> String {
        "conversation.colour.\(id.rawValue)"
    }

    /// A pin changes the group. Within each group, creation order stays stable while a turn runs.
    public static func ordered(_ sessions: [Session], pinned: Set<SessionID>) -> [Session] {
        sessions.sorted { left, right in
            let leftPinned = pinned.contains(left.id)
            let rightPinned = pinned.contains(right.id)
            if leftPinned != rightPinned { return leftPinned }
            if left.sortOrder != right.sortOrder { return left.sortOrder > right.sortOrder }
            return left.id.rawValue < right.id.rawValue
        }
    }

    /// Applies a sidebar drag while keeping pinned and unpinned rows in their own runs.
    public static func reordered(
        _ sessions: [Session], pinned: Set<SessionID>, from offsets: IndexSet, to destination: Int
    ) -> [Session]? {
        guard !offsets.isEmpty, offsets.allSatisfy(sessions.indices.contains),
              (0...sessions.count).contains(destination) else { return nil }
        let moving = offsets.map { sessions[$0] }
        var remaining = sessions.enumerated().compactMap { offset, session in
            offsets.contains(offset) ? nil : session
        }
        let adjusted = destination - offsets.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: adjusted)
        let oldPins = sessions.map { pinned.contains($0.id) }
        let newPins = remaining.map { pinned.contains($0.id) }
        return oldPins == newPins ? remaining : nil
    }

    public static func status(
        isRunning: Bool, isAwaitingPermission: Bool
    ) -> WorkspaceStatus? {
        if isAwaitingPermission { return .awaitingPermission }
        if isRunning { return .running }
        return nil
    }
}
