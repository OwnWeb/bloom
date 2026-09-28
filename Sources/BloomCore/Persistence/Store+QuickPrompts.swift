import Foundation

extension Store {
    // MARK: - Quick prompts

    /// The whole list, in the order the panel draws it before anything is searched for.
    public func quickPrompts() throws -> [QuickPrompt] {
        try db.query("SELECT * FROM quick_prompt ORDER BY sort_order, created_at, id")
            .map(Self.quickPrompt(from:))
    }

    public func quickPrompt(id: QuickPromptID) throws -> QuickPrompt? {
        try db.query("SELECT * FROM quick_prompt WHERE id = ?", [.text(id)])
            .first.map(Self.quickPrompt(from:))
    }

    /// Writes a new prompt. `insert` rather than `upsert`, because every column here is the
    /// owner's and a row that already exists is changed through `update(quickPromptID:)`: see the
    /// rule at the head of this file. A prompt with an id the table already holds is a bug rather
    /// than an edit, so the insert is left to fail rather than made to overwrite.
    ///
    /// The order it lands in is worked out here, inside the actor, so two prompts written in the
    /// same moment cannot both read the same maximum and share a place in the list.
    @discardableResult
    public func insert(_ prompt: QuickPrompt) throws -> QuickPrompt {
        var row = prompt
        row.sortOrder = try nextQuickPromptOrder()
        try insertQuickPromptRow(row)
        return row
    }

    /// Changes an existing prompt without writing the columns it did not mean to change.
    ///
    /// The same shape as `update(workspaceID:)`, and for the same reason: the row is read here,
    /// inside the actor, immediately before it is written back, with no suspension in between, so
    /// a form somebody sat in for a minute cannot carry the rest of the row back to what it looked
    /// like when they opened it.
    @discardableResult
    public func update(
        quickPromptID: QuickPromptID,
        _ change: @Sendable (inout QuickPrompt) -> Void
    ) throws -> QuickPrompt? {
        guard var row = try quickPrompt(id: quickPromptID) else { return nil }
        change(&row)
        try db.run(
            """
            UPDATE quick_prompt
            SET name = ?, symbol = ?, text = ?, sends_immediately = ?, opens_new_chat = ?
            WHERE id = ?
            """,
            [
                .text(row.name), .text(row.symbol), .text(row.text),
                .int(row.sendsImmediately ? 1 : 0), .int(row.opensNewChat ? 1 : 0),
                .text(quickPromptID),
            ]
        )
        row.id = quickPromptID
        return row
    }

    public func deleteQuickPrompt(id: QuickPromptID) throws {
        try db.run("DELETE FROM quick_prompt WHERE id = ?", [.text(id)])
    }

    /// Puts the built-ins in, once ever, and answers with the list as it stands afterwards.
    ///
    /// **Deleting a built-in has to stick.** So this compares the version the database has already
    /// seeded against `QuickPromptSeed.version` rather than comparing the built-in list against the
    /// table: a prompt the owner deleted is not missing, it is deleted, and nothing here can tell
    /// those apart by looking at the rows. Adding a second built-in later means a new entry with a
    /// higher `introducedIn` and a bump of the version, which inserts that one and resurrects
    /// nothing. See `QuickPromptSeed`.
    @discardableResult
    public func seedQuickPrompts(now: Date = Date()) throws -> [QuickPrompt] {
        let installed = Int(try setting(QuickPromptSeed.versionKey) ?? "") ?? 0
        let pending = QuickPromptSeed.pending(installed: installed)
        guard !pending.isEmpty else { return try quickPrompts() }

        var order = try nextQuickPromptOrder()
        for entry in pending {
            try insertQuickPromptRow(entry.prompt(sortOrder: order, now: now))
            order += 1
        }
        try setSetting(QuickPromptSeed.versionKey, String(QuickPromptSeed.version))
        return try quickPrompts()
    }

    /// Puts back the built-in quick prompts that are not in the library.
    ///
    /// **Asked for, never automatic**, which is the rule `QuickPromptSeed` opens with: a list
    /// reconciled on every launch is a list that resurrects what somebody deleted. This is the
    /// other side of that rule, and it exists because without it a deleted built-in was gone for
    /// this database for good with nothing anywhere saying so.
    ///
    /// It inserts and never updates. A built-in the owner has edited is not missing, so it is not
    /// touched; one they renamed is missing and comes back beside the renamed copy, which
    /// `QuickPromptSeed.missing` argues is the right way round.
    ///
    /// The seed version is deliberately left alone. It records how far the automatic seeding has
    /// got, this is not that, and writing it here would mean a restore on an old database quietly
    /// marking newer built-ins as already offered.
    ///
    /// Returns the whole library afterwards, so the caller redraws from one answer rather than
    /// reading again.
    @discardableResult
    public func restoreBuiltInQuickPrompts(now: Date = Date()) throws -> [QuickPrompt] {
        try db.transaction {
            let missing = QuickPromptSeed.missing(from: try quickPrompts())
            guard !missing.isEmpty else { return try quickPrompts() }
            var order = try nextQuickPromptOrder()
            for entry in missing {
                try insertQuickPromptRow(entry.prompt(sortOrder: order, now: now))
                order += 1
            }
            return try quickPrompts()
        }
    }

    private func nextQuickPromptOrder() throws -> Int {
        let highest = try db.query("SELECT COALESCE(MAX(sort_order), -1) AS m FROM quick_prompt")
            .first?.int("m") ?? -1
        return Int(highest) + 1
    }

    private func insertQuickPromptRow(_ prompt: QuickPrompt) throws {
        try db.run(
            """
            INSERT INTO quick_prompt (
                id, name, symbol, text, sends_immediately, opens_new_chat, sort_order, created_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(prompt.id), .text(prompt.name), .text(prompt.symbol), .text(prompt.text),
                .int(prompt.sendsImmediately ? 1 : 0), .int(prompt.opensNewChat ? 1 : 0),
                .int(Int64(prompt.sortOrder)),
                .double(prompt.createdAt.timeIntervalSince1970),
            ]
        )
    }
}
