import Foundation

extension Store {
    // MARK: - Settings

    /// Planning temporarily replaces the mode in the session row. Keep the implementation
    /// choice separately so starting in Plan and entering Plan through the composer agree.
    func rememberImplementationMode(for session: Session) throws {
        let key = PlanApproval.modeKey(sessionID: session.id)
        let remembered = try setting(key)
        let mode: PermissionMode
        if session.permissionMode != .plan {
            mode = PlanApproval.implementationMode(session.permissionMode)
        } else {
            guard remembered == nil else { return }
            mode = try planImplementationMode(sessionID: session.id, hasWorktree: session.workspaceID != nil)
        }
        if remembered != mode.rawValue { try setSetting(key, mode.rawValue) }
    }

    public func planImplementationMode(sessionID: SessionID, hasWorktree: Bool) throws -> PermissionMode {
        if let session = try session(id: sessionID), session.permissionMode != .plan {
            return PlanApproval.implementationMode(session.permissionMode)
        }
        if let raw = try setting(PlanApproval.modeKey(sessionID: sessionID)),
           let mode = PermissionMode(rawValue: raw) {
            return PlanApproval.implementationMode(mode)
        }
        guard hasWorktree else { return AskConversation.permissionMode }
        let configured = try setting(AppDefaults.Key.permissionMode).flatMap(PermissionMode.init(rawValue:))
        return PlanApproval.implementationMode(configured ?? AppDefaults.fallbackPermissionMode)
    }

    public func setting(_ key: String) throws -> String? {
        try db.query("SELECT value FROM settings WHERE key = ?", [.text(key)]).first?.string("value")
    }

    public func saveComposerControls(_ controls: ComposerControls, sessionID: SessionID) throws {
        try db.transaction {
            for (key, value) in controls.settings(sessionID: sessionID) {
                try setSetting(key, value)
            }
        }
    }

    /// Archive and replacement are one commit. A failed insert, preference or draft write must
    /// leave the original conversation reachable, and a second caller must not replace it twice.
    public func replaceWorkspaceConversation(id: SessionID, controls: ComposerControls) throws -> Session {
        try db.transaction {
            guard let current = try session(id: id), let workspaceID = current.workspaceID,
                  current.archivedAt == nil else {
                throw SQLiteError(message: "This conversation is no longer current.", sql: nil)
            }
            var next = Session(workspaceID: workspaceID, title: current.title, sortOrder: current.sortOrder)
            next.model = controls.model
            next.effort = controls.effort
            next.agentKind = controls.agentKind
            next.permissionMode = controls.permissionMode
            next.interactionMode = controls.interactionMode
            try upsert(next)
            for (key, value) in controls.settings(sessionID: next.id) {
                try setSetting(key, value)
            }
            _ = try update(sessionID: id) { $0.archivedAt = Date() }
            return next
        }
    }

    /// Ask tabs also carry their directory and persisted selection into the replacement.
    public func replaceAskConversation(
        id: SessionID, controls: ComposerControls, draft: String = ""
    ) throws -> Session {
        try db.transaction {
            guard let current = try session(id: id), current.workspaceID == nil,
                  current.archivedAt == nil else {
                throw SQLiteError(message: "This conversation is no longer current.", sql: nil)
            }
            var next = AskConversation.newSession(sortOrder: current.sortOrder)
            next.model = controls.model
            next.effort = controls.effort
            next.agentKind = controls.agentKind
            next.permissionMode = controls.permissionMode
            next.interactionMode = controls.interactionMode
            try upsert(next)
            for (key, value) in controls.settings(sessionID: next.id) {
                try setSetting(key, value)
            }
            try saveDraft(sessionID: next.id, body: draft)
            let directory = try setting(AskTabs.directoryKey(id))
                ?? AskConversation.directory(besideDatabaseAt: path)
            try setSetting(AskTabs.directoryKey(next.id), directory)
            try setSetting(AskTabs.selectionKey, next.id.rawValue)
            _ = try update(sessionID: id) { $0.archivedAt = Date() }
            return next
        }
    }

    /// Inserting the chat and its controls, draft, directory and selection is one transaction.
    public func createAskConversation(
        directory: String, controls: ComposerControls? = nil, draft: String = ""
    ) throws -> Session {
        try db.transaction {
            let existing = try sessionsWithoutWorkspace()
            var next = AskConversation.newSession(sortOrder: (existing.map(\.sortOrder).max() ?? -1) + 1)
            if let controls {
                next.model = controls.model
                next.effort = controls.effort
                next.agentKind = controls.agentKind
                next.permissionMode = controls.permissionMode
            next.interactionMode = controls.interactionMode
            }
            try upsert(next)
            if let controls {
                for (key, value) in controls.settings(sessionID: next.id) { try setSetting(key, value) }
            }
            try saveDraft(sessionID: next.id, body: draft)
            try setSetting(AskTabs.directoryKey(next.id), directory)
            try setSetting(AskTabs.selectionKey, next.id.rawValue)
            return next
        }
    }

    /// Closing a tab archives its transcript and records the neighbouring selection together.
    public func closeAskConversation(id: SessionID, selected: SessionID?) throws -> SessionID? {
        try db.transaction {
            let sessions = try sessionsWithoutWorkspace()
            guard sessions.count > 1, sessions.contains(where: { $0.id == id }) else { return selected }
            let next = AskTabs.selectionAfterClosing(id, selected: selected, sessions: sessions)
            _ = try update(sessionID: id) { $0.archivedAt = Date() }
            try setSetting(AskTabs.selectionKey, next?.rawValue)
            return next
        }
    }

    /// Every setting whose key starts with `prefix`, for a caller that keeps a family of them.
    public func settings(prefix: String) throws -> [(key: String, value: String)] {
        let pattern = prefix.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
        return try db.query("SELECT key, value FROM settings WHERE key LIKE ? ESCAPE '\\'", [.text(pattern)]).compactMap { row in
            guard let key = row.string("key"), let value = row.string("value") else { return nil }
            return (key, value)
        }
    }

    public func setSetting(_ key: String, _ value: String?) throws {
        if let value {
            try db.run(
                "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                [.text(key), .text(value)]
            )
        } else {
            try db.run("DELETE FROM settings WHERE key = ?", [.text(key)])
        }
    }
}
