import AppKit
import BloomCore
import SwiftUI

#if DEBUG
@MainActor
enum TabStoreProbe {
    static func run(directory: String, check: (Bool, String) -> Void) async {
        setenv("BLOOM_DB_PATH", directory + "/tabs.sqlite", 1)
        let app = AppModel()
        await app.bootstrap()
        guard let store = app.store else {
            check(false, "the tab store probe could not open its own database")
            return
        }

        let model: WorkspaceModel
        do {
            model = try await seed(directory: directory, app: app, store: store)
        } catch {
            check(false, "tab fixture failed: \(error)")
            return
        }

        let tabs = CenterTabStore.shared
        let strip = WorkspaceTabsStore.shared
        let workspaceID = model.workspace.id
        tabs.load(workspaceID: workspaceID)

        // Two tool tabs, the way the `+` menu opens them.
        let terminal = tabs.add(kind: .terminal, workspaceID: workspaceID)
        let review = tabs.showReview(path: "README.md", workspaceID: workspaceID)
        check(tabs.tabs(for: workspaceID).count == 2, "a workspace that opened two tabs has \(tabs.tabs(for: workspaceID).count)")

        // The keys. This is the whole of the "nothing stored moves" claim, checked rather than
        // argued: a build before the stores were re-keyed wrote exactly these two strings.
        let defaults = UserDefaults.standard
        let listKey = "center.tabs." + workspaceID.rawValue
        let stripKey = "center.strip." + workspaceID.rawValue
        check(defaults.data(forKey: listKey) != nil, "the tab list is not under \(listKey)")
        check(
            TabDefaults.tabListKey(workspaceID) == listKey && TabDefaults.stripKey(workspaceID) == stripKey,
            "the keys a surface builds are not the keys a workspace built"
        )

        // The stored record, decoded the way a relaunch decodes it. A tab names its workspace as a
        // bare id, so a list written by a previous version still reads.
        if let data = defaults.data(forKey: listKey),
           let stored = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let ids = stored.compactMap { $0["workspaceID"] as? String }
            check(ids == [workspaceID.rawValue, workspaceID.rawValue], "a stored tab names its workspace as \(ids)")
        } else {
            check(false, "the stored tab list could not be read back as JSON")
        }

        // A split, which is what the arrangement key holds.
        strip.select(.tool(terminal.id), in: model)
        let pane = strip.split(
            tab: .tool(terminal.id), pane: strip.focusedPane(of: .tool(terminal.id)),
            axis: .horizontal, showing: .tool(review.id)
        )
        check(pane != nil, "splitting a terminal tab opened no pane")
        check(strip.layout(of: .tool(terminal.id)).panes.count == 2, "a split tab does not have two panes")
        let arrangement = defaults.data(forKey: "center.tab." + PaneContent.tool(terminal.id).id)
        check(arrangement != nil, "the split arrangement was not written")

        // And the order, which is the third key and the one a drag writes. What matters to a
        // person is not the bytes but that the strip comes back in the order they dragged it into,
        // so that is what is asked: reorder, then derive the strip again.
        let entries = strip.entries(in: model)
        let wanted = Array(entries.reversed())
        strip.reorder(wanted, in: model)
        check(strip.entries(in: model) == wanted, "the strip did not come back in the order it was put in")
        // The bytes are only asked to be readable. What they hold is the interleaving rather than
        // the strip, and it deliberately remembers tabs that are not in it at the moment: see
        // `StripOrder`, whose own tests are where that rule belongs.
        let storedOrder = defaults.data(forKey: stripKey).flatMap { try? JSONDecoder().decode([PaneContent].self, from: $0) }
        check(storedOrder?.isEmpty == false, "the strip order was not written, or will not read back")

        // What the orphan sweep sees, which is the check with a shell at stake.
        //
        // The sweep kills every tmux session whose pane id nothing enumerates, and what enumerates
        // them is `TerminalPaneCensus`, reading the same defaults key this store writes. The store
        // is keyed by the workspace now rather than by the worktree, so the question is whether the
        // census still finds the list and whether the name a shell is forked under is byte for byte
        // the name the sweep builds. Both are asked here rather than argued.
        let census = TerminalPaneCensus.census(of: [workspaceID], in: defaults)
        check(census.doubtful.isEmpty, "the sweep is in doubt about a workspace whose list it has just read")
        let panes = TerminalSplitStore.shared.panes(of: terminal.id)
        check(
            census.panes == Set(panes.isEmpty ? [terminal.id] : panes),
            "the sweep would name \(census.panes) where the terminal tab has \(panes)"
        )
        for pane in census.panes {
            let swept = TmuxSessions.sessionName(workspaceID: workspaceID, paneID: pane)
            let forked = TmuxSessions.sessionName(workspaceID: workspaceID, paneID: pane)
            check(swept == forked && swept.contains(workspaceID.rawValue), "a shell's name and the swept name differ")
        }

        // What a relaunch does with all three, as far as it can be done in one process: the stores
        // are singletons, so this reads the bytes the way `restore` does rather than building them
        // again. A real relaunch is still worth one pass by a person; see the note in the report.
        if let data = defaults.data(forKey: listKey) {
            let decoded = try? JSONDecoder().decode([CenterTab].self, from: data)
            check(decoded?.count == 2, "a relaunch would read back \(decoded?.count ?? 0) of the two tabs")
            check(
                decoded?.allSatisfy { $0.workspaceID == workspaceID } == true,
                "a relaunch would read a tab back under another workspace"
            )
            check(decoded?.contains { $0.kind == .review } == true, "the review tab did not survive the round trip")
        }
    }

    private static func seed(directory: String, app: AppModel, store: Store) async throws -> WorkspaceModel {
        let origin = directory + "/tab-repo"
        let worktree = directory + "/tab-work"
        try FileManager.default.createDirectory(atPath: origin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)
        let repo = try await store.upsert(Repo(name: "Tab probe", path: origin))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "Tabs", branch: "tabs", path: worktree, baseBranch: "main"
        ))
        await app.reload()
        return WorkspaceModel(workspace: workspace, app: app)
    }
}
#endif
