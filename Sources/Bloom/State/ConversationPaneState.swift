import Foundation
import Observation
import BloomCore

/// Live browser and terminal panes around one project-free conversation. The value in
/// `ConversationLayout` is saved per conversation; native views stay here across tab switches.
@MainActor
@Observable
final class ConversationPaneState {
    let sessionID: SessionID
    let directory: String
    private(set) var layout: ConversationLayout
    private(set) var browsers: [ConversationPaneID: BrowserSession] = [:]

    init(sessionID: SessionID, directory: String) {
        self.sessionID = sessionID
        self.directory = directory
        let saved = UserDefaults.standard.data(forKey: Self.key(sessionID))
            .flatMap { try? JSONDecoder().decode(ConversationLayout.self, from: $0) }
        if let saved, saved.isValid {
            layout = saved
        } else {
            layout = ConversationLayout()
        }
        for tab in layout.tabs {
            for pane in tab.panes.values where pane.kind == .terminal {
                TerminalSessionStore.shared.reopenPanes(of: pane.id.rawValue)
            }
        }
    }

    static func key(_ id: SessionID) -> String { "conversation.panes.\(id.rawValue)" }

    func open(_ kind: ConversationLayout.Kind, url: String = "") {
        _ = layout.open(kind, url: url)
        save()
    }

    func split(tabID: ConversationPaneID, paneID: ConversationPaneID, axis: SplitAxis, kind: ConversationLayout.Kind) {
        _ = layout.split(tabID: tabID, paneID: paneID, axis: axis, opening: kind)
        save()
    }

    func closePane(tabID: ConversationPaneID, paneID: ConversationPaneID) {
        guard let removed = layout.closePane(tabID: tabID, paneID: paneID) else { return }
        retire(removed)
        save()
    }

    func closeTab(_ id: ConversationPaneID) {
        let removed = layout.closeTab(id)
        guard !removed.isEmpty else { return }
        for pane in removed { retire(pane) }
        save()
    }

    func select(_ id: ConversationPaneID) {
        layout.select(id)
        save()
    }

    func focus(_ pane: ConversationPaneID, in tab: ConversationPaneID) {
        layout.focus(pane, in: tab)
        save()
    }

    func setRatio(_ ratio: Double, at path: [Int], in tab: ConversationPaneID) {
        layout.setRatio(ratio, at: path, in: tab)
    }

    func persistRatio() { save() }

    func rename(_ title: String, tabID: ConversationPaneID) {
        layout.rename(title, tabID: tabID)
        save()
    }

    func updatePage(_ page: BrowserTabTitle.BrowserPage, paneID: ConversationPaneID, tabID: ConversationPaneID) {
        guard let before = layout.tab(tabID)?.pane(paneID)?.url,
              before != page.address else { return }
        layout.setURL(page.address, paneID: paneID, in: tabID)
        save()
    }

    /// A browser is created only when its pane is first drawn. Restoring five tabs must not fetch
    /// five pages before the reader has selected one.
    func prepareBrowser(_ pane: ConversationLayout.Pane) {
        guard pane.kind == .browser, browsers[pane.id] == nil else { return }
        browsers[pane.id] = BrowserSession(url: pane.url, root: directory)
    }

    func browser(for id: ConversationPaneID) -> BrowserSession? { browsers[id] }

    /// Archiving stops processes and pages without forgetting the layout. Restoring the
    /// conversation brings its tabs back in the same arrangement.
    func suspend() {
        for tab in layout.tabs {
            for pane in tab.panes.values where pane.kind == .terminal {
                TerminalSessionStore.shared.closePanes(of: pane.id.rawValue, preserveLayout: true)
            }
        }
        for browser in browsers.values { browser.stop() }
        browsers.removeAll()
    }

    func discard() {
        suspend()
        Self.discardStoredLayout(for: sessionID)
    }

    static func discardStoredLayout(for id: SessionID) {
        let storageKey = key(id)
        let layout = UserDefaults.standard.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode(ConversationLayout.self, from: $0) }
        for tab in layout?.tabs ?? [] {
            for pane in tab.panes.values where pane.kind == .terminal {
                TerminalSplitStore.shared.discard(ownerID: pane.id.rawValue)
            }
        }
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    private func retire(_ pane: ConversationLayout.Pane) {
        switch pane.kind {
        case .chat: break
        case .terminal: TerminalSessionStore.shared.closePanes(of: pane.id.rawValue)
        case .browser:
            browsers.removeValue(forKey: pane.id)?.stop()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(layout) else { return }
        UserDefaults.standard.set(data, forKey: Self.key(sessionID))
    }
}
