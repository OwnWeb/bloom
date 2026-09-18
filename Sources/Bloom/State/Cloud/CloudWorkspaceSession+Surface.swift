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
            preview: allows("preview")
        )
    }

    var isRunning: Bool {
        state.chats.values.contains { $0.isRunning }
    }
}
