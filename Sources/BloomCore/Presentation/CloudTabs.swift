import Foundation

/// The tabs of one Cloud workspace: its chats, the tool tabs somebody opened beside them, the
/// order they were dragged into and which one is in front.
///
/// **The rules are the local column's, not a second set.** Which things earn a tab is `TabSet`,
/// the interleaved order is `StripOrder`, and what the selection becomes when a tab closes is
/// `TabClosure`, exactly as `WorkspaceTabsStore` asks them for a worktree on this Mac. What this
/// type adds is the half a Cloud workspace has that a local one does not: its chats live on a
/// machine rather than in this database, and its tool tabs are a line in user defaults keyed by
/// runbloom.app's id.
///
/// Here rather than beside the views because every rule in it is a decision, and `Tests` cannot
/// see `Sources/Bloom`.
public struct CloudTabs: Codable, Hashable, Sendable {
    /// Everything but a chat that has a tab: a terminal, the changes, the setup output, the notes.
    public struct Tool: Codable, Hashable, Sendable, Identifiable {
        public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
            case terminal
            case changes
            case setup
            case notes

            /// What a new tab of this kind is called. The words are `PaneNaming`'s where there is
            /// one, so a Cloud tab and a local tab of the same kind are never named differently.
            public var title: String {
                switch self {
                case .terminal: PaneNaming.terminal
                case .changes: PaneNaming.changes
                case .setup: PaneNaming.setup
                case .notes: PaneNaming.notes
                }
            }

            /// Whether a workspace has at most one of these. Opening the changes twice points the
            /// one tab at another file rather than making a second, which is the rule the local
            /// column keeps for its review and its notes; a terminal is the one you can have many
            /// of.
            public var isUnique: Bool { self != .terminal }
        }

        public var id: String
        public var kind: Kind
        /// The name somebody typed over the default, and nil while it wears the default.
        public var name: String?
        /// The terminal on the machine this tab is attached to, for a shell or a run script.
        public var terminalName: String?
        /// The run script this terminal was opened for, when it was.
        public var scriptID: String?

        public init(id: String = newID(), kind: Kind, name: String? = nil, terminalName: String? = nil, scriptID: String? = nil) {
            self.id = id
            self.kind = kind
            self.name = name
            self.terminalName = terminalName
            self.scriptID = scriptID
        }

        public var title: String { name ?? kind.title }
    }

    public private(set) var tools: [Tool] = []
    /// The strip's interleaved order, the same shape `StripOrder` reads and writes for a local
    /// workspace.
    public private(set) var order: [PaneContent] = []
    /// The tab somebody chose, which is only a hint: `selection(chats:)` resolves it against what
    /// is actually there, so a tab that has gone cannot leave the column pointing at nothing.
    public var chosen: PaneContent?

    public init() {}

    // MARK: Reading

    /// The strip, left to right: the machine's chats and the tool tabs opened here, in the order
    /// they were dragged into.
    public func entries(chats: [SessionID]) -> [PaneContent] {
        StripOrder.entries(sessions: chats, tools: tools.map(\.id), stored: order)
    }

    /// The tab in front. The chosen one while it is still there, otherwise the first, which for a
    /// workspace that has just been opened is its first chat.
    public func selection(chats: [SessionID]) -> PaneContent? {
        let entries = entries(chats: chats)
        if let chosen, entries.contains(chosen) { return chosen }
        return entries.first
    }

    public func tool(_ content: PaneContent) -> Tool? {
        guard case .tool(let id) = content else { return nil }
        return tools.first { $0.id == id }
    }

    public func tool(kind: Tool.Kind) -> Tool? {
        tools.first { $0.kind == kind }
    }

    /// What a tab is called in the strip.
    public func title(of content: PaneContent, chats: [ChatTitle]) -> String {
        switch content {
        case .chat(let id): chats.first { $0.id == id }?.title ?? PaneNaming.chat
        case .tool(let id): tools.first { $0.id == id }?.title ?? PaneNaming.terminal
        }
    }

    /// One chat's name, as the strip needs it.
    public struct ChatTitle: Hashable, Sendable {
        public var id: SessionID
        public var title: String

        public init(id: SessionID, title: String) {
            self.id = id
            self.title = title
        }
    }

    // MARK: Changing

    /// Records the chats the machine has, so a chat opened while this workspace was closed keeps
    /// its place in the strip rather than arriving at the end.
    public mutating func noteChats(_ chats: [SessionID]) {
        let updated = StripOrder.updated(sessions: chats, tools: tools.map(\.id), stored: order)
        if updated != order { order = updated }
    }

    /// Opens a tool tab and selects it. A kind a workspace has only one of is revealed rather than
    /// opened twice, which is the rule the local column keeps for the review and the notes.
    /// - Parameter chats: the machine's chats, so the new tab lands after them rather than in
    ///   front of them. The local column reads the same list off its model for the same reason.
    @discardableResult
    public mutating func open(_ tool: Tool, chats: [SessionID]) -> PaneContent {
        if tool.kind.isUnique, let existing = self.tool(kind: tool.kind) {
            chosen = .tool(existing.id)
            return .tool(existing.id)
        }
        tools.append(tool)
        order = StripOrder.updated(sessions: chats, tools: tools.map(\.id), stored: order)
        chosen = .tool(tool.id)
        return .tool(tool.id)
    }

    public mutating func select(_ content: PaneContent) {
        chosen = content
    }

    /// Closes a tab. Chats are the machine's, so closing one is reported back to the caller to do
    /// there; everything else is forgotten here.
    ///
    /// - Returns: the chat to close on the machine, when that is what was closed.
    @discardableResult
    public mutating func close(_ content: PaneContent, chats: [SessionID]) -> SessionID? {
        let entries = entries(chats: chats)
        let next = TabClosure.selectionAfterClosing(content, selected: selection(chats: chats), tabs: entries)
        if case .tool(let id) = content {
            tools.removeAll { $0.id == id }
        }
        order.removeAll { $0 == content }
        chosen = next
        if case .chat(let id) = content { return id }
        return nil
    }

    /// Writes down the order the strip was dragged into.
    public mutating func reorder(_ drawn: [PaneContent], chats: [SessionID]) {
        guard let rewritten = StripOrder.rewritten(drawn, sessions: chats, tools: tools.map(\.id), stored: order) else { return }
        order = rewritten
    }

    /// Renames a tool tab. A chat is renamed on the machine, which the caller does, because its
    /// name is what every other client sees.
    public mutating func rename(_ content: PaneContent, to name: String) {
        guard case .tool(let id) = content, let index = tools.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tools[index].name = trimmed.isEmpty ? nil : trimmed
    }

    /// Opens the setup tab by itself while setup is running or has failed, once per state, so a
    /// workspace being created shows what it is doing and one that failed says so, and a reader
    /// who closes it is not given it back.
    ///
    /// - Returns: whether it opened one.
    @discardableResult
    public mutating func revealSetupIfNeeded(state: String?, chats: [SessionID]) -> Bool {
        guard let state, ["running", "pending", "failed"].contains(state) else { return false }
        guard tool(kind: .setup) == nil, !hasSeenSetup(state) else { return false }
        seenSetupStates.insert(state)
        let tab = Tool(kind: .setup)
        tools.append(tab)
        order = StripOrder.updated(sessions: chats, tools: tools.map(\.id), stored: order)
        // Selected only when there is nothing else to read yet: a workspace mid setup with a chat
        // in front should not be taken off it.
        if chats.isEmpty { chosen = .tool(tab.id) }
        return true
    }

    private func hasSeenSetup(_ state: String) -> Bool { seenSetupStates.contains(state) }
    private var seenSetupStates: Set<String> = []
}
