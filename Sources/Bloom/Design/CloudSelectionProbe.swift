import AppKit
import BloomCore

#if DEBUG
/// A Cloud workspace asked the selection questions before chats arrive and after two chats share a tab.
///
/// **This is a crash, written down.** `be.spatie.bloom.cloud` 0.1.0 died with `EXC_BAD_ACCESS` and
/// "thread stack size exceeded due to excessive recursion" the first time the owner made a Cloud
/// workspace, about ten thousand frames deep, alternating between `WorkspaceTabsStore.selectedTab`
/// and `CloudWorkspaceSession.activeChat`: the store resolved its selection by asking the workspace
/// which chat was in front, and that workspace answers that question by asking the store. A local
/// workspace keeps its own `activeSessionID`, so the pair terminates there and nothing had ever
/// been caught. A brand new Cloud workspace has no chats at all, which is where neither side can
/// break the tie by finding an answer, and it is reached from the menu bar rebuilding rather than
/// from anything a person does, so it fires as the workspace appears.
///
/// The fix is `WorkspaceSurface.preferredChatID`, which a workspace whose selection IS the store's
/// answers nil to. What this probe holds is the shape of the failure rather than the fix: it drives
/// the same three reads, and on the code before the fix it does not fail, it takes the process with
/// it. **A crash here is this probe failing.** There is no catching a stack overflow in the process
/// that has it, so the bound is the process, and the script reports the death as a failure.
@MainActor
enum CloudSelectionProbe {
    static func run(check: (Bool, String) -> Void) async {
        let cloud = CloudWorkspaces()
        let session = CloudWorkspaceSession(id: CloudWorkspaceID("01probe"), cloud: cloud)
        let tabs = WorkspaceTabsStore.shared
        let root = PaneContent.chat(SessionID("01chat"))
        let focused = PaneContent.chat(SessionID("02chat"))
        // The review probe's bundle keeps defaults between runs. Remove the previous split so
        // the one-chat check below starts with the same empty arrangement each time.
        tabs.forget(focused, workspaceID: session.surfaceID)

        // The state a workspace is in for the couple of minutes after it is created: it exists,
        // its machine has not answered yet, and nothing has been read.
        check(session.chats.isEmpty, "the probe's workspace was supposed to have no chats")
        check(!session.hasReadChats, "the probe's workspace was supposed to have read nothing")

        // The rule that makes the pair terminate. Asserted directly, because it is the whole fix
        // and the three reads below are only its consequences.
        check(session.preferredChatID == nil, "a Cloud workspace offered the strip a chat to open on")

        // What the crash report's first frames were, in the order it reached them.
        check(session.activeChat == nil, "a workspace with no chats answered with one")
        check(WorkspaceTabsStore.shared.selectedTab(in: session) == nil, "an empty strip had a tab in front")
        // And the menu bar's own question, which is what was on the stack: `BloomCommands`
        // rebuilds its items whenever the window's state moves, and asks this of the workspace in
        // front so it can enable or disable Rename Tab.
        check(renamableTab(of: session) == nil, "the menu found a tab to rename in an empty strip")

        // A chat arrives from the machine. The strip has no selection of its own, so it opens on
        // the first entry, which is the answer the workspace can no longer give it.
        session.absorbForProbe(chat: "01chat")
        let entry = WorkspaceTabsStore.shared.selectedTab(in: session)
        check(entry == .chat(SessionID("01chat")), "the strip did not open on the machine's only chat")
        check(session.activeChat?.id == SessionID("01chat"), "the workspace does not agree with the strip")

        // The focused pane is chat B inside a tab rooted on A. Before the fix, selecting A
        // adopted B through a setter that selected B as a tab. B was claimed by A, so selection
        // resolved back to A and repeated until the main thread exhausted its stack.
        session.absorbForProbe(chat: "02chat")
        if let pane = tabs.split(tab: root, axis: .horizontal, showing: focused) {
            tabs.focus(pane, in: root, of: session)
            tabs.select(root, in: session)
            check(tabs.selectedTab(in: session) == root, "the split tab did not stay selected")
            check(session.selectedChatID == SessionID("02chat"), "the focused chat was not active")
            check(session.activeChat?.id == SessionID("02chat"), "the workspace chose the tab root over its focused pane")
        } else {
            check(false, "the two chats did not form a split tab")
        }
        tabs.forget(focused, workspaceID: session.surfaceID)
    }

    /// `BloomCommands.renamableTab`, which is private to it. Copied rather than exposed: what is
    /// under test is the pair of reads it makes, and widening a menu's helper to be probed would be
    /// the probe changing the thing it is measuring.
    private static func renamableTab(of workspace: some WorkspaceSurface) -> PaneContent? {
        guard let selected = WorkspaceTabsStore.shared.selectedTab(in: workspace) else { return nil }
        let kind = CenterTabStore.shared.tabs(for: workspace.surfaceID).first { $0.id == selected.id }?.kind
        return TabRenaming.canRename(selected, tabKind: kind) ? selected : nil
    }
}
#endif
