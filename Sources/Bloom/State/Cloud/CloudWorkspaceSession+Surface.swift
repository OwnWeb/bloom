import AppKit
import BloomClient
import Foundation
import SwiftUI
import BloomCore
import BloomProtocol

/// A Cloud workspace as the shared review views see it: the same protocol `WorkspaceModel` answers
/// out of a worktree, answered here out of the machine.
///
/// The reads are the ones already built for the Changes pane (`CloudChanges`, which keeps the
/// snapshot and the patch cache so nothing is read twice), plus the whole file list, which is the
/// `files` operation. What is not here is what a Cloud workspace cannot do yet; those are
/// `capabilities`, and the views ask before they offer.
extension CloudWorkspaceSession: WorkspaceSurface {
    var surfaceID: WorkspaceSurfaceID { .cloud(id) }

    var surfaceName: String {
        state.workspace?.name ?? cloud.item(id)?.displayName ?? "Cloud workspace"
    }

    var surfaceBranch: String {
        state.workspace?.branch ?? cloud.item(id)?.displayBranch ?? ""
    }

    var surfaceBaseBranch: String {
        state.workspace?.baseBranch ?? cloud.item(id)?.baseBranch ?? "main"
    }

    /// Nil, and every capability that would have read it is already false.
    var worktreePath: String? { nil }

    var capabilities: WorkspaceCapabilities {
        .cloud(
            // runbloom.app answers whether this person may merge, as GitHub sees them, so the
            // control is greyed for somebody without push access rather than failing when pressed.
            managePullRequest: github.state?.canMerge == true,
            preview: allows("preview"),
            // The machine's own `file` and `write_file`, which carry a revision and refuse a write
            // made against a version somebody else has moved on from. The token has to say this
            // Mac may touch files at all: a reader who may only watch gets no editor, which is the
            // same answer the machine would give and is better given before the button is pressed.
            editFiles: allows("files"),
            // Notes on a diff are this reader's own, kept on this Mac until they are sent, so they
            // need nothing of the machine's until the turn goes. What the turn needs is the right
            // to send one at all. See `CloudChanges.reviewComments`.
            reviewComments: allows("prompt")
        )
    }

    var isRunning: Bool {
        state.chats.values.contains { $0.isRunning }
    }

    /// What this machine is doing, for the sidebar, or nil while there is no live stream to say.
    ///
    /// **Nil is the honest answer for a connection that is not listening**, and it is what sends
    /// the row back to runbloom.app's poll. A workspace nobody has open is the poll's to describe;
    /// one whose stream is open is described by the stream, because the poll said `running` for a
    /// turn that had already ended and nothing told it otherwise. See `CloudWorkspaceStatus.init`.
    var sidebarActivity: CloudWorkspaceStatus.Activity? {
        guard phase == .live else { return nil }
        if let setup = state.setup, ["pending", "running"].contains(setup.state) {
            return .settingUp(step: setup.step)
        }
        // The kind a question is drawn as is the summary's word for it, and the stream carries the
        // ask itself rather than a label, so what the stream answers is that there IS one. The
        // summary's kind is used when it has one, which keeps the row's sentence what it was.
        if state.chats.values.contains(where: { !$0.questions.isEmpty }) {
            return .waiting(kind: cloud.item(id)?.summary?.waiting?.kind ?? "question")
        }
        if isRunning { return .running }
        return .idle
    }
}
