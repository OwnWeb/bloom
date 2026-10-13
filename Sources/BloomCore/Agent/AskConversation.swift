import Foundation

/// Shared rules for a conversation that has no project or Git worktree.
///
/// The former Ask Bloom panel used the same persisted sessions. Its directory and title remain
/// readable so existing conversations appear in the new sidebar section with their history.
public enum AskConversation {
    /// The placeholder title for a conversation that has not been used yet.
    public static let title = "New conversation"
    public static let legacyTitle = "Ask Bloom"

    public static let placeholder = "Ask anything…"

    /// The directory for new project-free conversations. Older sessions retain their saved
    /// directory, which may be the former Ask directory or one the owner chose in Settings.
    public static func workspaceDirectory(
        besideDatabaseAt databasePath: String, id: SessionID
    ) -> String {
        let container = (databasePath as NSString).deletingLastPathComponent
        let root = (container as NSString).appendingPathComponent("Conversations")
        return (root as NSString).appendingPathComponent(id.rawValue)
    }

    public static func prepareWorkspaceDirectory(
        besideDatabaseAt databasePath: String, id: SessionID
    ) -> String? {
        let path = workspaceDirectory(besideDatabaseAt: databasePath, id: id)
        do {
            try FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return path
        } catch {
            return nil
        }
    }

    /// The legacy working directory for conversations made before the sidebar flow.
    /// Each existing session keeps the directory stored under its id. See `AskTabs`.
    ///
    /// **This is a permission decision rather than a tidiness one.** These chats follow the owner's
    /// default permission mode, so its working directory still needs a deliberate boundary.
    /// A chat started in the owner's home directory would treat every file in it as inside the
    /// working directory. With a mode that asks before leaving that directory, an empty one keeps
    /// those reaches visible and pushes the agent towards the audited bridge tools. Full access
    /// still means full access, as the permission picker explains.
    ///
    /// Beside the database rather than at a fixed path, for the reason `BridgeOwnerToken.beside`
    /// gives: `Store.databaseDirectoryName` is the one rule that decides which copy of Bloom a
    /// process is, so Bloom and Bloom Dev get their own without a second rule to keep in step.
    ///
    /// It stays empty of anything the owner did not put there, rather than empty for ever, and
    /// that is the honest reading of the paragraph above. Attaching a file to a prompt copies it
    /// under `.bloom/attachments` here, exactly as it would in a worktree, and the agent can then
    /// read it without asking. That is not a hole, it is what attaching a file means: the reach
    /// the mode is protecting is the one nobody made on purpose.
    public static func directory(besideDatabaseAt databasePath: String) -> String {
        let container = (databasePath as NSString).deletingLastPathComponent
        return (container as NSString).appendingPathComponent("Ask")
    }

    /// The same, made on disk. Answers with the path, or nil when it could not be created, which
    /// is a chat that must not start: a `cwd` the CLI cannot enter is a process that dies at spawn,
    /// and falling back to any other directory would undo the whole paragraph above.
    public static func prepareDirectory(besideDatabaseAt databasePath: String) -> String? {
        let path = directory(besideDatabaseAt: databasePath)
        do {
            try FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return path
        } catch {
            return nil
        }
    }

    /// A brand new chat, with no project worktree behind it.
    public static func newSession(id: SessionID = .new(), sortOrder: Int = 0) -> Session {
        Session(
            id: id,
            workspaceID: nil,
            title: title,
            permissionMode: AppDefaults.fallbackPermissionMode,
            sortOrder: sortOrder
        )
    }

    /// What the empty pane says before anything has been asked.
    ///
    /// **It used to lead with what this chat cannot do.** "This chat has no worktree. ... It
    /// cannot change a file." Both sentences are true and neither belongs on the first screen: a
    /// worktree is Bloom's word for a thing the reader has not met yet, and an empty pane that
    /// opens by listing its own limits reads as an apology for existing. The limits are real and
    /// they are said where they change a decision, which is the permission menu's footnote.
    ///
    /// It starts with an open invitation, since the conversation can be about any topic.
    public static let emptyHeading = "Start a conversation"
    public static let emptyDetail =
        "Ask a question, explore an idea, or keep a discussion going without a project."

    /// The title a conversation takes from its first message, or nil when it already has one.
    ///
    /// Both the current placeholder and the old Ask Bloom title take their name from the first
    /// message. A title somebody typed is never overwritten.
    public static func automaticTitle(current: String, prompt: String) -> String? {
        guard current == title || current == legacyTitle else { return nil }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Git.title(from: trimmed, maxLength: 40)
    }

    /// Whether a conversation has never been used: never named, never started.
    ///
    /// The sidebar leaves these out. Closing the last conversation can leave a blank session
    /// behind, and a row for it would make the archive look as if it had failed.
    public static func isBlank(_ session: Session) -> Bool {
        (session.title == title || session.title == legacyTitle) && session.agentSessionID == nil
    }

    /// What the empty pane offers to send in one click, under `suggestionsHeading`.
    ///
    /// Each suggestion is a complete prompt, ready to send.
    public static let suggestionsHeading = "Try asking:"
    public static let suggestions = [
        "Help me think through an idea",
        "Summarise this document",
        "Draft an outline for a post",
    ]
}
