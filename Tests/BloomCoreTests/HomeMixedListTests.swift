import Foundation
import Testing
@testable import BloomCore

@Suite("Home conversations among workspaces")
struct HomeMixedListTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private func workspace(_ name: String, at date: Date) -> HomeRow {
        HomeRow(workspace: Workspace(
            id: WorkspaceID(name), repoID: RepoID("repo"), name: name,
            branch: "main", path: "/tmp/\(name)", baseBranch: "main",
            state: .archived, lastActivityAt: date
        ))
    }

    private func conversation(_ name: String, activeAt date: Date) -> Session {
        var session = Session(
            id: SessionID(name), workspaceID: nil, title: name, updatedAt: date
        )
        session.archivedAt = date.addingTimeInterval(600)
        return session
    }

    private func listing(_ rows: [HomeRow]) -> HomeListing {
        HomeListing(
            groups: [HomeGroup(id: "existing", title: "Existing", rows: rows)],
            shown: rows.count, considered: rows.count, archived: rows.count,
            shownArchived: rows.count
        )
    }

    @Test("archived conversations share date headings and order with workspaces")
    func sharesDateBuckets() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let recent = workspace("recent", at: now.addingTimeInterval(-60))
        let older = workspace("older", at: now.addingTimeInterval(-300))
        let chat = conversation("chat", activeAt: now.addingTimeInterval(-120))

        let groups = HomeMixedList.build(
            listing: listing([older, recent]), conversations: [chat],
            filter: HomeFilter(scope: .archived), now: now, calendar: calendar
        )

        #expect(groups.count == 1)
        #expect(groups.first?.title == "Today")
        let ids = groups.first?.items.map(\.id) ?? []
        #expect(ids == [
            .workspace(WorkspaceID("recent")),
            .conversation(SessionID("chat")),
            .workspace(WorkspaceID("older"))
        ])
    }

    @Test("a conversation in another date bucket is not pulled into a separate category")
    func crossesDateBuckets() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let chat = conversation("chat", activeAt: yesterday)

        let groups = HomeMixedList.build(
            listing: listing([workspace("today", at: now)]), conversations: [chat],
            filter: HomeFilter(), now: now, calendar: calendar
        )

        #expect(groups.map(\.title) == ["Today", "Yesterday"])
        #expect(groups[1].items.map(\.id) == [.conversation(SessionID("chat"))])
    }
}
