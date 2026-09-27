import Foundation

extension Store {
    // MARK: - Terminal tabs

    /// Every row, because the one caller left is the migration that drains the table and it wants
    /// all of them. Per workspace, it was a query each and `terminal_tabs` has no index on
    /// `workspace_id`, so each was a full scan. Nothing is indexed instead: after the migration
    /// the table is empty, and the only other statement here is keyed on the primary key.
    public func terminalTabs() throws -> [TerminalTab] {
        try db.query(
            "SELECT * FROM terminal_tabs ORDER BY workspace_id, sort_order"
        ).map {
            TerminalTab(
                id: TerminalTabID($0.string("id") ?? newID()),
                workspaceID: WorkspaceID($0.string("workspace_id") ?? ""),
                title: $0.string("title") ?? "Terminal",
                sortOrder: Int($0.int("sort_order") ?? 0)
            )
        }
    }

    public func upsert(_ tab: TerminalTab) throws {
        try db.run(
            """
            INSERT INTO terminal_tabs (id, workspace_id, title, sort_order) VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET title = excluded.title, sort_order = excluded.sort_order
            """,
            [.text(tab.id), .text(tab.workspaceID), .text(tab.title), .int(Int64(tab.sortOrder))]
        )
    }

    public func deleteTerminalTab(id: TerminalTabID) throws {
        try db.run("DELETE FROM terminal_tabs WHERE id = ?", [.text(id)])
    }
}
