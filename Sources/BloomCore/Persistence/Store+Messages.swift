import Foundation

extension Store {
    // MARK: - Messages

    /// A chat's rows in sequence order.
    public func messages(
        sessionID: SessionID, afterSeq: Int = -1, limit: Int = 100_000
    ) throws -> [Message] {
        return try db.query(
            "SELECT * FROM messages WHERE session_id = ? AND seq > ? ORDER BY seq LIMIT ?",
            [.text(sessionID), .int(Int64(afterSeq)), .int(Int64(limit))]
        ).map(Self.message(from:))
    }

    /// How many rows a chat has.
    public func messageCount(sessionID: SessionID) throws -> Int {
        Int(try db.query("SELECT COUNT(*) AS c FROM messages WHERE session_id = ?",
                         [.text(sessionID)]).first?.int("c") ?? 0)
    }

    public func nextSeq(sessionID: SessionID) throws -> Int {
        let rows = try db.query(
            "SELECT COALESCE(MAX(seq), -1) AS m FROM messages WHERE session_id = ?",
            [.text(sessionID)]
        )
        return Int(rows.first?.int("m") ?? -1) + 1
    }

    /// Insert a row at a sequence number the caller chose. Prefer `appendNext`, which cannot hand
    /// the same number to two writers.
    @discardableResult
    public func append(_ message: Message) throws -> Message {
        var stored = message
        stored.id = try insert(message)
        return stored
    }

    /// Allocate the next sequence number and insert the row in one go.
    ///
    /// Reading `nextSeq` and then calling `append` is two hops onto this actor, and a second
    /// writer that lands in between reserves the number that was just handed out: both rows then
    /// claim the same position. Doing both inside one call, inside one transaction, is what makes
    /// the allocation atomic. `UNIQUE(session_id, seq)` catches the case that outlives this
    /// process (a second `Store` on the same file), and losing that race is a retry, not an error.
    @discardableResult
    public func appendNext(
        sessionID: SessionID,
        kind: MessageKind,
        payload: Data,
        durationMS: Int? = nil,
        refID: String? = nil,
        createdAt: Date = Date()
    ) throws -> Message {
        var lastError: Error?
        for _ in 0..<Self.seqAllocationAttempts {
            do {
                return try db.transaction {
                    let seq = try nextSeqLocked(sessionID: sessionID)
                    var message = Message(
                        sessionID: sessionID,
                        seq: seq,
                        kind: kind,
                        payload: payload,
                        createdAt: createdAt,
                        durationMS: durationMS,
                        refID: refID
                    )
                    message.id = try insert(message)
                    return message
                }
            } catch let error as SQLiteError where Self.isSeqConflict(error) {
                lastError = error
            }
        }
        throw lastError ?? SQLiteError(message: "could not allocate a sequence number", sql: nil)
    }

    /// Enough attempts to outlast a burst of writers, few enough that a genuinely stuck database
    /// surfaces as an error instead of spinning.
    private static let seqAllocationAttempts = 16

    private static func isSeqConflict(_ error: SQLiteError) -> Bool {
        error.message.contains("UNIQUE constraint failed: messages.session_id")
    }

    func nextSeqLocked(sessionID: SessionID) throws -> Int {
        let rows = try db.query(
            "SELECT COALESCE(MAX(seq), -1) AS m FROM messages WHERE session_id = ?",
            [.text(sessionID)]
        )
        return Int(rows.first?.int("m") ?? -1) + 1
    }

    func insert(_ message: Message) throws -> Int64 {
        let id = try db.run(
            """
            INSERT INTO messages (session_id, seq, kind, payload, created_at, duration_ms, ref_id)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(message.sessionID), .int(Int64(message.seq)), .text(message.kind.rawValue),
                .blob(message.payload), .double(message.createdAt.timeIntervalSince1970),
                message.durationMS.map { .int(Int64($0)) } ?? .null,
                message.refID.map { .text($0) } ?? .null,
            ]
        )
        // Here rather than in a trigger, and here rather than in a task afterwards: this is the
        // one place a transcript row is created, so indexing it here is what makes the index a
        // fact about the table rather than a cache that can drift. `appendNext` already wraps
        // this in a transaction; `append` does not, and a single statement is its own.
        try indexMessage(id: id, kind: message.kind, payload: message.payload)
        return id
    }

    private func indexMessage(id: Int64, kind: MessageKind, payload: Data) throws {
        guard let body = TranscriptSearchText.indexable(kind: kind, payload: payload) else { return }
        try db.run(
            "INSERT INTO message_search (rowid, body) VALUES (?, ?)",
            [.int(id), .text(body)]
        )
    }

    // MARK: - Transcript search

    /// Where the one time backfill has got to: the lowest message id that is already indexed.
    /// In `settings` rather than in a column or a file because it has to survive a crash, and
    /// because the whole of the resume logic is then one integer that a `SELECT` can read.
    static let backfillCursorKey = "transcriptSearchBackfillCursor"

    /// How many rows one backfill step does.
    ///
    /// Small enough that the actor is handed back between batches, so a turn arriving mid backfill
    /// waits milliseconds rather than minutes. Measured on the owner's database: a batch of a
    /// thousand takes about 90ms, of which most is the JSON walk.
    public static let backfillBatch = 1_000

    public struct BackfillProgress: Sendable, Hashable {
        /// Rows read in this step, indexed or not: a row with no words in it is progress too.
        public var scanned: Int
        /// Rows still below the cursor, so a caller can show it or log it.
        public var remaining: Int
        public var isFinished: Bool { remaining == 0 }
    }

    /// Indexes one batch of the transcripts that existed before this feature did, newest first.
    ///
    /// **Newest first is the point.** Months of messages take a while to walk, and the workspace
    /// somebody searches for in the first minute is nearly always a recent one, so the index is
    /// useful long before it is complete rather than only at the end.
    ///
    /// **Safe to interrupt.** The batch and the cursor move in one transaction, so a process
    /// killed halfway through leaves the cursor where the last complete batch left it and the next
    /// launch redoes at most one batch. Redoing a batch is harmless: `INSERT OR REPLACE` on the
    /// rowid overwrites whatever was there.
    ///
    /// **Never blocks the launch.** Nothing calls this during `init`. The app kicks it off after
    /// its first screen is drawn and loops until `isFinished`, and every call is one hop onto this
    /// actor that yields in between.
    @discardableResult
    public func indexOlderTranscripts(batch: Int = backfillBatch) throws -> BackfillProgress {
        let cursor = Int64(try setting(Self.backfillCursorKey) ?? "") ?? 0
        guard cursor > 0 else { return BackfillProgress(scanned: 0, remaining: 0) }

        return try db.transaction {
            let rows = try db.query(
                "SELECT id, kind, payload FROM messages WHERE id < ? ORDER BY id DESC LIMIT ?",
                [.int(cursor), .int(Int64(batch))]
            )

            var lowest = cursor
            for row in rows {
                guard let id = row.int("id") else { continue }
                lowest = min(lowest, id)
                let kind = MessageKind(rawValue: row.string("kind") ?? "") ?? .system
                guard let body = TranscriptSearchText.indexable(
                    kind: kind, payload: row.data("payload") ?? Data()
                ) else { continue }
                try db.run(
                    "INSERT OR REPLACE INTO message_search (rowid, body) VALUES (?, ?)",
                    [.int(id), .text(body)]
                )
            }

            // A short batch means there was nothing more below the cursor, and the cursor goes to
            // zero rather than to the lowest id seen: zero is the one value that says "finished"
            // without needing a second key to say it.
            let next = rows.count < batch ? 0 : lowest
            try db.run(
                "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
                [.text(Self.backfillCursorKey), .text(String(next))]
            )

            let remaining = next == 0 ? 0 : Int(try db.query(
                "SELECT COUNT(*) AS c FROM messages WHERE id < ?", [.int(next)]
            ).first?.int("c") ?? 0)
            return BackfillProgress(scanned: rows.count, remaining: remaining)
        }
    }

    /// True while there is transcript history not yet in the index, so the search screen can say
    /// so instead of quietly returning half an answer.
    public func isTranscriptIndexIncomplete() throws -> Bool {
        (Int64(try setting(Self.backfillCursorKey) ?? "") ?? 0) > 0
    }

    /// Every workspace whose transcript matches, best first.
    ///
    /// Two queries rather than one. The first takes the top few hundred rows by bm25 and builds
    /// the snippets, which is the expensive half and is why it is capped. The second counts the
    /// matches per workspace over the whole index, so a workspace that appears once in the
    /// candidate list can still say it has ninety matches. Counting is an index-only walk and
    /// measured at a fraction of the ranked query.
    ///
    /// **Archived workspaces are included.** Old work is exactly what somebody is hunting for when
    /// they cannot remember which workspace it was, and the archive is where old work goes. The
    /// caller decides how to draw the two; the search does not decide for it.
    ///
    /// Measured on the owner's database, 1035 messages: between 0.1ms and 5.2ms, the slowest of
    /// them being a search for "the". Measured on a synthetic database built by replicating that
    /// same history until it held 264,960 messages and 573MB of payloads: 63ms for a real word and
    /// 180ms for "the", of which the ranked half is 54ms and 127ms and the count is the rest. That
    /// second number is a ceiling rather than a forecast, because replicating one history makes
    /// every term 256 times commoner than it would be in a database that large for real, and it is
    /// commonness that bm25 has to walk.
    public func searchTranscripts(
        _ query: String,
        limit: Int = TranscriptSearch.candidateLimit
    ) throws -> [TranscriptWorkspaceMatches] {
        guard let expression = TranscriptSearch.matchExpression(for: query) else { return [] }

        // `bm25` rather than `rank` so the score comes back with the row and can be looked at.
        // The snippet is built by FTS5 rather than in Swift because it already knows which terms
        // matched where, and doing it here would mean shipping whole message bodies across the
        // actor to find out. See `TranscriptSearch.snippet(from:)` for what the marks become.
        let rows = try db.query(
            """
            SELECT ms.rowid AS message_id, m.session_id, m.seq, m.kind, m.created_at,
                   s.workspace_id, s.title,
                   snippet(message_search, 0, ?, ?, '…', 14) AS marked,
                   bm25(message_search) AS score
            FROM message_search ms
            JOIN messages m ON m.id = ms.rowid
            JOIN sessions s ON s.id = m.session_id
            WHERE message_search MATCH ?
            ORDER BY score
            LIMIT ?
            """,
            [
                .text(TranscriptSearch.openMark), .text(TranscriptSearch.closeMark),
                .text(expression), .int(Int64(limit)),
            ]
        )

        let matches = rows.map { row in
            TranscriptMatch(
                messageID: row.int("message_id") ?? 0,
                workspaceID: WorkspaceID(row.string("workspace_id") ?? ""),
                sessionID: SessionID(row.string("session_id") ?? ""),
                sessionTitle: row.string("title") ?? "Session",
                seq: Int(row.int("seq") ?? 0),
                kind: MessageKind(rawValue: row.string("kind") ?? "") ?? .system,
                createdAt: row.date("created_at") ?? Date(),
                snippet: TranscriptSearch.snippet(from: row.string("marked") ?? ""),
                score: row.double("score") ?? 0
            )
        }

        var totals: [WorkspaceID: Int] = [:]
        for row in try db.query(
            """
            SELECT s.workspace_id AS workspace_id, COUNT(*) AS c
            FROM message_search ms
            JOIN messages m ON m.id = ms.rowid
            JOIN sessions s ON s.id = m.session_id
            WHERE message_search MATCH ?
            GROUP BY s.workspace_id
            """,
            [.text(expression)]
        ) {
            totals[WorkspaceID(row.string("workspace_id") ?? "")] = Int(row.int("c") ?? 0)
        }

        return TranscriptSearch.group(matches, totals: totals)
    }

    /// Puts the database back to what one written before this index existed looks like: the
    /// messages are all there and none of them is searchable. Internal, and only the suite that
    /// tests the backfill calls it, because a database in that state is the one thing the backfill
    /// has to cope with and there is no other way to produce it.
    func forgetTranscriptIndexForTesting() throws {
        try db.execute("DELETE FROM message_search;")
        try rewindTranscriptBackfillForTesting()
    }

    /// Puts the cursor back above every row, which is what an interrupted backfill that never got
    /// to commit its cursor leaves behind.
    func rewindTranscriptBackfillForTesting() throws {
        let highest = try db.query("SELECT COALESCE(MAX(id), 0) AS m FROM messages").first?.int("m") ?? 0
        try db.run(
            "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
            [.text(Self.backfillCursorKey), .text(String(highest + 1))]
        )
    }

    /// Find the stored toolUse row a tool_result belongs to.
    public func message(sessionID: SessionID, refID: String) throws -> Message? {
        try db.query(
            "SELECT * FROM messages WHERE session_id = ? AND ref_id = ? ORDER BY seq DESC LIMIT 1",
            [.text(sessionID), .text(refID)]
        ).first.map(Self.message(from:))
    }
}
