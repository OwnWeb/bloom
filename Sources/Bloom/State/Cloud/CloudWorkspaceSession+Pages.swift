import BloomCore
import Foundation

/// The two kinds of page a Cloud workspace shows in a browser tab: its own app, through the preview
/// exchange, and a port forwarded to this Mac, at `localhost`.
///
/// **Both are browser tabs, and only the address tells them apart.** The preview pane ignores the
/// tab's address and asks runbloom.app for a fresh one every time, so a forwarded page put in that
/// tab would show the project's app instead. `WorkspacePorts.forwardedLocalPort` is the rule, and
/// every lookup of "the workspace's browser" goes through `isPreviewTab` so the preview is never
/// found in a forward's tab or the other way round.
extension CloudWorkspaceSession {
    func isPreviewTab(_ tab: CenterTab) -> Bool {
        tab.kind == .browser && WorkspacePorts.forwardedLocalPort(in: tab.url) == nil
    }

    /// Opens a forwarded page in a tab of its own, or brings forward the tab already showing it.
    ///
    /// A tab per address rather than one for every forward, because Vite and Mailpit are two pages
    /// somebody flips between, and one tab that kept replacing itself would lose the other's place.
    func openForwardedPage(_ url: URL, title: String) {
        let store = CenterTabStore.shared
        let address = url.absoluteString
        let tab = store.tabs(for: surfaceID).first { $0.kind == .browser && $0.url == address }
            ?? store.add(kind: .browser, workspaceID: surfaceID, url: address, title: title)
        WorkspaceTabsStore.shared.reveal(.tool(tab.id), in: self)
    }

    /// A screenshot of a page in one of this workspace's panes, into the composer of the chat in
    /// front. Answers the alert to show when it could not be done, or nil when it was.
    ///
    /// **The bytes never touch a worktree on either kind of workspace, which is why this works at
    /// all.** `ComposerHandoff` writes them where the workspace says attachments go, which for a
    /// Cloud chat is the staging directory, and the turn uploads them to the machine when it goes.
    /// So the picture of an app running on a machine is sent to the agent on that machine, and
    /// nothing about the road it takes is particular to the pane it was taken in.
    func attachSnapshot(of browser: BrowserSession) async -> BloomAlert? {
        let data: Data
        do {
            data = try await browser.snapshot()
        } catch {
            return BloomAlert(title: "That page could not be captured", message: error.readableMessage)
        }
        // Named after the page, avoiding what the chat is already carrying, exactly as the local
        // pane names its own.
        let taken = Set(
            PromptAttachmentStore.shared
                .attachments(for: (activeChat?.id ?? chats.first?.id)?.rawValue ?? "")
                .map(\.filename)
        )
        let name = BrowserSnapshot.filename(for: browser.displayAddress, avoiding: taken)
        let outcome = await ComposerHandoff.attach([.image(data, format: .png, named: name)], to: self)
        guard let failure = outcome.failure else { return nil }
        return BloomAlert(title: "That screenshot was not attached", message: failure)
    }
}
