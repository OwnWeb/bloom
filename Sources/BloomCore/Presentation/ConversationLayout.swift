import Foundation

/// Tabs and split panes around one project-free conversation. The chat stays reachable while
/// terminals and browsers come and go, and no pane needs a Git workspace to exist.
public struct ConversationLayout: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case chat
        case terminal
        case browser
    }

    public struct Pane: Codable, Sendable, Equatable, Identifiable {
        public var id: ConversationPaneID
        public var kind: Kind
        public var title: String
        public var url: String

        public init(id: ConversationPaneID, kind: Kind, title: String, url: String = "") {
            self.id = id
            self.kind = kind
            self.title = title
            self.url = url
        }
    }

    public struct Tab: Codable, Sendable, Equatable, Identifiable {
        public var id: ConversationPaneID
        public var title: String
        public var layout: SplitLayout
        public var panes: [ConversationPaneID: Pane]

        public func pane(_ id: ConversationPaneID) -> Pane? { panes[id] }
    }

    public static let chatID = ConversationPaneID("chat")
    public private(set) var tabs: [Tab]
    public private(set) var selectedTabID: ConversationPaneID

    public init() {
        let chat = Pane(id: Self.chatID, kind: .chat, title: "Conversation")
        tabs = [Tab(
            id: Self.chatID, title: chat.title,
            layout: SplitLayout(pane: chat.id.rawValue), panes: [chat.id: chat]
        )]
        selectedTabID = Self.chatID
    }

    public var selectedTab: Tab? { tabs.first { $0.id == selectedTabID } }
    public func tab(_ id: ConversationPaneID) -> Tab? { tabs.first { $0.id == id } }

    /// A stored layout is used only when its chat and every live pane can still be named.
    public var isValid: Bool {
        guard tabs.first?.id == Self.chatID,
              tabs[0].panes[Self.chatID]?.kind == .chat,
              Set(tabs.map(\.id)).count == tabs.count,
              tabs.contains(where: { $0.id == selectedTabID }) else { return false }
        return tabs.allSatisfy { tab in
            Set(tab.layout.panes.map(ConversationPaneID.init)) == Set(tab.panes.keys)
                && tab.panes.allSatisfy { $0.key == $0.value.id }
        }
    }

    @discardableResult
    public mutating func open(_ kind: Kind, title: String? = nil, url: String = "") -> Pane {
        let pane = Self.makePane(kind, title: title, url: url, among: tabs)
        tabs.append(Tab(
            id: pane.id, title: pane.title,
            layout: SplitLayout(pane: pane.id.rawValue), panes: [pane.id: pane]
        ))
        selectedTabID = pane.id
        return pane
    }

    @discardableResult
    public mutating func split(
        tabID: ConversationPaneID, paneID: ConversationPaneID, axis: SplitAxis, opening kind: Kind
    ) -> Pane? {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return nil }
        let pane = Self.makePane(kind, title: nil, url: "", among: tabs)
        guard tabs[index].layout.split(paneID.rawValue, axis: axis, into: pane.id.rawValue) else { return nil }
        tabs[index].panes[pane.id] = pane
        return pane
    }

    /// Closing a pane never removes the original conversation. A tool tab's last pane closes its
    /// tab, while a split tab keeps the panes that remain.
    @discardableResult
    public mutating func closePane(tabID: ConversationPaneID, paneID: ConversationPaneID) -> Pane? {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              let pane = tabs[index].panes[paneID] else { return nil }
        if tabID == Self.chatID && paneID == Self.chatID { return nil }
        if tabs[index].layout.paneCount == 1 {
            guard tabID != Self.chatID else { return nil }
            tabs.remove(at: index)
            if selectedTabID == tabID { selectedTabID = tabs[max(0, index - 1)].id }
            return pane
        }
        guard tabs[index].layout.close(paneID.rawValue) else { return nil }
        tabs[index].panes[paneID] = nil
        return pane
    }

    /// Returns every pane whose shell or browser must be closed with a tool tab.
    @discardableResult
    public mutating func closeTab(_ id: ConversationPaneID) -> [Pane] {
        guard id != Self.chatID, let index = tabs.firstIndex(where: { $0.id == id }) else { return [] }
        let removed = Array(tabs.remove(at: index).panes.values)
        if selectedTabID == id { selectedTabID = tabs[max(0, index - 1)].id }
        return removed
    }

    public mutating func select(_ id: ConversationPaneID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
    }

    public mutating func focus(_ paneID: ConversationPaneID, in tabID: ConversationPaneID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].layout.setFocus(paneID.rawValue)
    }

    public mutating func setRatio(_ ratio: Double, at path: [Int], in tabID: ConversationPaneID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].layout.setRatio(ratio, at: path)
    }

    public mutating func rename(_ title: String, tabID: ConversationPaneID) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].title = name
    }

    public mutating func setURL(_ url: String, paneID: ConversationPaneID, in tabID: ConversationPaneID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              var pane = tabs[index].panes[paneID], pane.kind == .browser else { return }
        pane.url = url
        tabs[index].panes[paneID] = pane
    }

    private static func makePane(_ kind: Kind, title: String?, url: String, among tabs: [Tab]) -> Pane {
        let count = tabs.flatMap { $0.panes.values }.filter { $0.kind == kind }.count
        let base: String
        switch kind {
        case .chat: base = "Conversation"
        case .terminal: base = "Terminal"
        case .browser: base = "Browser"
        }
        let name = title ?? (count == 0 ? base : "\(base) \(count + 1)")
        return Pane(id: .new(), kind: kind, title: name, url: url)
    }
}
