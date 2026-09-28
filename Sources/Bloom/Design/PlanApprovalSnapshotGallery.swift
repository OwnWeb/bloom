import SwiftUI
import BloomCore

struct PlanApprovalSnapshotGallery: View {
    private func card(mode: PermissionMode, decision: String? = nil) -> some View {
        PermissionAskRowView(
            ask: PermissionAsk(
                requestID: "plan-\(mode.rawValue)", toolName: "ExitPlanMode",
                input: .object(["plan": .string("Create two files, then update the first.")]),
                requiresUserInteraction: true, implementationMode: mode
            ),
            decision: decision, note: "", projectName: "Bloom"
        )
    }

    /// Long enough to have what a real plan has: a heading, a list, code and a table, which is
    /// the Markdown that used to be read as plain text.
    private static let plan = """
        # Rename the store's write path

        Split `upsert` from `update` so a stale row cannot roll a newer one back.

        1. Add `update(workspaceID:)` that reads inside the actor.
        2. Move the three callers that hand in a row read earlier.
        3. Cover it in `WorkspaceWriteIsolationTests`.

        | File | Change |
        | --- | --- |
        | `Store.swift` | new method |
        | `WorkspaceModel.swift` | three callers |
        """

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            PlanRowView(markdown: Self.plan)
            card(mode: .acceptEdits)
            card(mode: .auto)
            card(mode: .bypassPermissions)
            card(mode: .acceptEdits, decision: "approve-plan-acceptEdits")
            card(mode: .acceptEdits).frame(width: 350)
        }
        .padding(20)
        .background(Palette.windowBackground)
    }
}
