import Foundation

/// A workspace or project-free conversation in the same Home list.
public enum HomeMixedItem: Identifiable, Sendable {
    case workspace(HomeRow)
    case conversation(Session)

    public var id: HomeMixedItemID {
        switch self {
        case .workspace(let row): .workspace(row.id)
        case .conversation(let session): .conversation(session.id)
        }
    }

    var date: Date {
        switch self {
        case .workspace(let row): row.workspace.lastActivityAt
        // Archiving does not make an old conversation new work in the dated list.
        case .conversation(let session): session.updatedAt
        }
    }

    var bytes: Int {
        switch self {
        case .workspace(let row): row.bytes ?? 0
        case .conversation: 0
        }
    }

    var sortKey: String {
        switch self {
        case .workspace(let row): "workspace:\(row.id.rawValue)"
        case .conversation(let session): "conversation:\(session.id.rawValue)"
        }
    }
}

public enum HomeMixedItemID: Hashable, Sendable {
    case workspace(WorkspaceID)
    case conversation(SessionID)
}

public struct HomeMixedGroup: Identifiable, Sendable {
    public var id: HomeMixedGroupID
    public var title: String
    public var items: [HomeMixedItem]

    public init(id: HomeMixedGroupID, title: String, items: [HomeMixedItem]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

/// Interleaves conversations with HomeList's already filtered workspace rows.
public enum HomeMixedList {
    public static func build(
        listing: HomeListing,
        conversations: [Session],
        filter: HomeFilter,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [HomeMixedGroup] {
        var items = listing.groups.flatMap(\.rows).map(HomeMixedItem.workspace)
        items.append(contentsOf: conversations.map(HomeMixedItem.conversation))
        guard !items.isEmpty else { return [] }

        let order = HomeOrder.applies(scope: filter.scope, searching: listing.isSearching)
            ? filter.order : .recent
        switch order {
        case .recent:
            items.sort { first, second in
                if first.date != second.date { return first.date > second.date }
                return first.sortKey < second.sortKey
            }
        case .largest:
            items.sort { first, second in
                if first.bytes != second.bytes { return first.bytes > second.bytes }
                return first.sortKey < second.sortKey
            }
        }

        if listing.isSearching {
            let title = conversations.isEmpty ? "Workspaces" : "Results"
            return [HomeMixedGroup(id: HomeMixedGroupID("results"), title: title, items: items)]
        }
        if let heading = order.heading {
            return [HomeMixedGroup(id: HomeMixedGroupID("order-\(order.rawValue)"), title: heading, items: items)]
        }

        var groups: [HomeMixedGroup] = []
        for item in items {
            let bucket = HomeList.bucket(for: item.date, now: now, calendar: calendar)
            if groups.last?.id == HomeMixedGroupID(bucket.id) {
                groups[groups.count - 1].items.append(item)
            } else {
                groups.append(HomeMixedGroup(
                    id: HomeMixedGroupID(bucket.id), title: bucket.title, items: [item]
                ))
            }
        }
        return groups
    }
}
