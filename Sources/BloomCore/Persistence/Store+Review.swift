import Foundation

extension Store {
    // MARK: - Review comments

    public func reviewComments(workspaceID: WorkspaceID) throws -> [ReviewComment] {
        try db.query(
            "SELECT * FROM review_comments WHERE workspace_id = ? ORDER BY file_path, line, created_at, id",
            [.text(workspaceID)]
        ).map(Self.reviewComment(from:))
    }

    public func reviewComments(workspaceID: WorkspaceID, filePath: String) throws -> [ReviewComment] {
        try db.query(
            """
            SELECT * FROM review_comments WHERE workspace_id = ? AND file_path = ?
            ORDER BY line, created_at, id
            """,
            [.text(workspaceID), .text(filePath)]
        ).map(Self.reviewComment(from:))
    }

    /// The ones that actually go out with the next message.
    public func attachedReviewComments(workspaceID: WorkspaceID) throws -> [ReviewComment] {
        try db.query(
            """
            SELECT * FROM review_comments WHERE workspace_id = ? AND attached = 1
            ORDER BY file_path, line, created_at, id
            """,
            [.text(workspaceID)]
        ).map(Self.reviewComment(from:))
    }

    /// Upsert rather than insert, so the composer can save an edited comment by writing the value
    /// it already holds instead of having to know whether that value has been to disk before.
    @discardableResult
    public func upsert(_ comment: ReviewComment) throws -> ReviewComment {
        try db.run(
            """
            INSERT INTO review_comments (
                id, workspace_id, file_path, side, line, line_text,
                context_before, context_after, body, created_at, attached, span
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                file_path = excluded.file_path,
                side = excluded.side,
                line = excluded.line,
                line_text = excluded.line_text,
                context_before = excluded.context_before,
                context_after = excluded.context_after,
                body = excluded.body,
                attached = excluded.attached,
                span = excluded.span
            """,
            [
                .text(comment.id), .text(comment.workspaceID), .text(comment.filePath),
                .text(comment.side.rawValue), .int(Int64(comment.anchor.line)),
                .text(comment.anchor.text),
                .text(Self.encodeContext(comment.anchor.before)),
                .text(Self.encodeContext(comment.anchor.after)),
                .text(comment.body), .double(comment.createdAt.timeIntervalSince1970),
                .int(comment.isAttached ? 1 : 0), .int(Int64(comment.anchor.span)),
            ]
        )
        return comment
    }

    /// Only the body, because that is the only thing an edit changes. Rewriting the whole row would
    /// let a stale copy held by the editor put the anchor back to where the line used to be.
    public func updateReviewCommentBody(id: ReviewCommentID, body: String) throws {
        try db.run("UPDATE review_comments SET body = ? WHERE id = ?", [.text(body), .text(id)])
    }

    public func setReviewCommentAttached(id: ReviewCommentID, attached: Bool) throws {
        try db.run(
            "UPDATE review_comments SET attached = ? WHERE id = ?",
            [.int(attached ? 1 : 0), .text(id)]
        )
    }

    /// What "Remove from chat" does to the whole set once the message has gone out. The comments
    /// stay readable in the diff, they just stop being sent again with every following turn.
    public func detachReviewComments(workspaceID: WorkspaceID) throws {
        try db.run(
            "UPDATE review_comments SET attached = 0 WHERE workspace_id = ?",
            [.text(workspaceID)]
        )
    }

    public func deleteReviewComment(id: ReviewCommentID) throws {
        try db.run("DELETE FROM review_comments WHERE id = ?", [.text(id)])
    }

    // MARK: - Viewed files

    /// Every tick this workspace carries, however stale. Whether one still holds is
    /// `ReviewedFiles.isViewed`, against the diff the poll last reported: a mark is given for a
    /// fingerprint rather than for a path, and deciding here would mean this actor knowing what
    /// git said a moment ago.
    public func reviewedFiles(workspaceID: WorkspaceID) throws -> [ReviewedFile] {
        try db.query(
            "SELECT * FROM reviewed_files WHERE workspace_id = ? ORDER BY file_path",
            [.text(workspaceID)]
        ).map(Self.reviewedFile(from:))
    }

    /// Ticks one file, or re-ticks it against the diff it has now.
    ///
    /// `upsert` is right here for the reason `addReviewComment` gives: every column is written
    /// from a value built in this call, and there is no other writer to carry a stale one back.
    /// The primary key is the pair, so ticking a file twice is one row rather than a second one
    /// nobody can tell from the first.
    public func markReviewed(_ mark: ReviewedFile) throws {
        try db.run(
            """
            INSERT INTO reviewed_files (workspace_id, file_path, fingerprint, viewed_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(workspace_id, file_path) DO UPDATE SET
                fingerprint = excluded.fingerprint,
                viewed_at = excluded.viewed_at
            """,
            [
                .text(mark.workspaceID), .text(mark.path), .text(mark.fingerprint),
                .double(mark.viewedAt.timeIntervalSince1970),
            ]
        )
    }

    public func clearReviewed(workspaceID: WorkspaceID, path: String) throws {
        try db.run(
            "DELETE FROM reviewed_files WHERE workspace_id = ? AND file_path = ?",
            [.text(workspaceID), .text(path)]
        )
    }

    /// Every tick on one workspace at once, which is what "start this pass again" means.
    public func clearReviewed(workspaceID: WorkspaceID) throws {
        try db.run("DELETE FROM reviewed_files WHERE workspace_id = ?", [.text(workspaceID)])
    }

    public func deleteReviewComments(workspaceID: WorkspaceID) throws {
        try db.run("DELETE FROM review_comments WHERE workspace_id = ?", [.text(workspaceID)])
    }
}
