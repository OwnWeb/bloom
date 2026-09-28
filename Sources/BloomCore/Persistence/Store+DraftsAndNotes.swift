import Foundation

extension Store {
    // MARK: - Drafts

    public func draft(sessionID: SessionID) throws -> String {
        try db.query("SELECT body FROM drafts WHERE session_id = ?", [.text(sessionID)])
            .first?.string("body") ?? ""
    }

    public func saveDraft(sessionID: SessionID, body: String) throws {
        if body.isEmpty {
            try db.run("DELETE FROM drafts WHERE session_id = ?", [.text(sessionID)])
        } else {
            try db.run(
                "INSERT INTO drafts (session_id, body) VALUES (?, ?) ON CONFLICT(session_id) DO UPDATE SET body = excluded.body",
                [.text(sessionID), .text(body)]
            )
        }
    }

    // MARK: - Workspace notes

    /// The workspace's note, or nothing when it has never had one. Nothing and an empty note are
    /// the same fact here, because `saveNote` deletes the row rather than storing a blank.
    public func note(workspaceID: WorkspaceID) throws -> WorkspaceNote? {
        try db.query(
            "SELECT * FROM workspace_notes WHERE workspace_id = ?", [.text(workspaceID)]
        ).first.map {
            WorkspaceNote(
                workspaceID: WorkspaceID($0.string("workspace_id") ?? workspaceID.rawValue),
                body: $0.string("body") ?? "",
                updatedAt: $0.date("updated_at") ?? Date()
            )
        }
    }

    /// Writes the workspace's note, or removes it when what is left is blank.
    ///
    /// It touches no other table, and in particular it does not touch `workspaces`. The pane that
    /// calls this is the slowest writer in the app and it must not be able to carry a stale
    /// workspace row back with it. See `WorkspaceNote`.
    public func saveNote(workspaceID: WorkspaceID, body: String, at date: Date = Date()) throws {
        let storable = WorkspaceNote.storable(body)
        if storable.isEmpty {
            try db.run("DELETE FROM workspace_notes WHERE workspace_id = ?", [.text(workspaceID)])
        } else {
            try db.run(
                """
                INSERT INTO workspace_notes (workspace_id, body, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(workspace_id)
                DO UPDATE SET body = excluded.body, updated_at = excluded.updated_at
                """,
                [.text(workspaceID), .text(storable), .double(date.timeIntervalSince1970)]
            )
        }
    }
}
