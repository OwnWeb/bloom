import Foundation

/// The chat that belongs to Bloom rather than to a workspace: what it is called, where it runs,
/// and what it is allowed to assume.
///
/// Everything the conversation itself needs already exists. `BridgeIdentity.owner` is a caller in
/// no workspace, `BridgeOwnerToken` is the credential that outlives a relaunch, and eleven owner
/// tools already list projects, list workspaces with their checks, register a repository and cut a
/// worktree. This type is the four decisions that were left: the directory, the mode, the name and
/// the words.
public enum AskConversation {
    /// What the chat is called, in the sidebar and on its row.
    public static let title = "Ask Bloom"

    /// Without host context, Ask Bloom picked an installed Conductor skill to create workspaces.
    /// Both backends receive these instructions when starting or resuming an Ask conversation.
    public static let instructions = """
    You are Ask Bloom, running inside the Bloom macOS app. Bloom manages the user's projects, \
    workspaces and agent conversations. This conversation belongs to Bloom and has no workspace \
    of its own.

    When the user asks to create, open, inspect or manage projects or workspaces, use Bloom by \
    default unless they explicitly name another app. Use the connected Bloom MCP tools. Discover \
    them with tool search if needed: project_list and workspace_list find existing work, \
    project_add registers a repository, and workspace_start creates a workspace and starts its \
    agent with the supplied prompt. Include any requested exploration or implementation in that \
    opening prompt, and let Bloom choose its configured workspace directory.

    Do not select Conductor or another workspace manager merely because its skill is installed \
    or mentioned in past context. If Bloom's tools are unavailable or fail, report the problem \
    instead of silently creating workspaces elsewhere. Follow the current permission mode and \
    any approval requests from the tools.
    """

    /// The placeholder in the composer. It says what this chat is for, because a chat with no
    /// worktree looks exactly like a chat with one until you ask it something it cannot do.
    public static let placeholder = "Ask about your projects and workspaces, or ask for one"

    /// The fallback working directory, used until the owner chooses a folder in Settings.
    /// Each conversation keeps the directory it started in. See `AskTabs`.
    ///
    /// **This is a permission decision rather than a tidiness one.** Ask Bloom follows the owner's
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

    /// An Ask conversation can keep a picker choice while Bloom is open. On the next launch it
    /// starts from the current default, including a default preset and Claude Code's Plan switch.
    /// The mode is mapped through the conversation's own backend because an older conversation
    /// need not use the backend currently selected for new sessions.
    public static func modeOnOpening(
        stored: PermissionMode,
        defaults: AppDefaults,
        agentKind: AgentKind,
        isFirstOpenSinceLaunch: Bool
    ) -> PermissionMode? {
        guard isFirstOpenSinceLaunch else { return nil }
        let preferred = (defaults.planMode && agentKind != .codex
            ? PermissionMode.plan : defaults.permissionMode).nearest(on: agentKind)
        return stored == preferred ? nil : preferred
    }

    /// A brand new Ask chat, with no workspace behind it.
    public static func newSession(sortOrder: Int = 0) -> Session {
        Session(
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
    /// So this says what to ask it for, in the order somebody would want it: start something, find
    /// out where everything stands, then go to the thing you found.
    public static let emptyHeading = "Ask Bloom anything about your work"
    public static let emptyDetail =
        "Start a new project or a workspace, ask what is running and what needs you, "
        + "find the workspace with the failing checks, and open it."

    /// The title a conversation takes from its first message, or nil when it already has one.
    ///
    /// Every conversation is made as "Ask Bloom", so a rail of them read "Ask Bloom" down the whole
    /// column. The first line of the first thing asked is what a person would call it, and it is
    /// there the moment the message is sent, with no model to wait on. A title somebody typed is
    /// never overwritten, because only the default is replaced.
    public static func automaticTitle(current: String, prompt: String) -> String? {
        guard current == title else { return nil }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Git.title(from: trimmed, maxLength: 40)
    }

    /// Whether a conversation has never been used: never named, never started.
    ///
    /// The rail leaves these out. Closing the last conversation leaves a blank one behind so the
    /// panel keeps a composer to type into, and a rail with one "Ask Bloom" row in it after you
    /// closed everything looked like the close had not worked.
    public static func isBlank(_ session: Session) -> Bool {
        session.title == title && session.agentSessionID == nil
    }

    /// What the empty pane offers to send in one click, under `suggestionsHeading`.
    ///
    /// Each is a whole question, answered with nothing else typed: a chip that needs finishing is
    /// a chip that makes somebody click, then type, then send, which is the clicking around the
    /// owner asked this pane to stop. Every one is something the bridge's tools can actually do.
    public static let suggestionsHeading = "Try asking Bloom:"
    public static let suggestions = [
        "What needs my attention right now?",
        "Which workspaces have failing checks?",
        "What is running at the moment?",
        "Which workspaces did I touch yesterday?",
        "Archive the workspaces whose pull requests are merged",
    ]
}
