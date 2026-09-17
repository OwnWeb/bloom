import BloomClient
import BloomCore
import SwiftUI

/// The chat pane of a Cloud workspace: the selected chat's transcript and composer, or what to do
/// when there is no chat yet.
struct CloudChatArea: View {
    var session: CloudWorkspaceSession
    @Environment(AppModel.self) private var app

    /// Bumped when a transcript model was made, which is outside observation, so the body reads
    /// it again.
    @State private var prepared: SessionID?

    var body: some View {
        content
            .task(id: session.selectedChatID) {
                guard let id = session.selectedChatID else { return }
                session.transcript(for: id)
                prepared = id
            }
    }

    @ViewBuilder
    private var content: some View {
        if let id = session.selectedChatID, prepared == id || session.existingTranscript(for: id) != nil,
           let transcript = session.existingTranscript(for: id) {
            // The app's own chat pane, the one a local workspace is drawn with. What differs is
            // the workspace under it: no side conversations, no worktree behind the composer, and
            // a sentence above it when runbloom.app would refuse the turn. See `WorkspaceSurface`.
            ChatPaneView(transcript: transcript, model: session, pane: id.rawValue)
                .id(id)
        } else if session.selectedChatID != nil {
            Palette.windowBackground
        } else if isSettingUp {
            // The first few minutes of a new Cloud workspace, where there is no chat yet and the
            // only thing happening is setup. Its output is the one honest thing to show.
            EmptyStateView(
                glyph: "hammer",
                title: "Setting up this Cloud workspace",
                message: session.heldPrompt.map { "Your first message goes as soon as it is ready: “\($0.text)”" }
                    ?? "It is cloning the repository and running the project's setup. This takes a few minutes the first time.",
                actionTitle: "Watch Setup",
                action: { session.open(.setup) }
            )
        } else if let held = session.heldPrompt {
            EmptyStateView(
                glyph: "clock",
                title: "Your first message is waiting",
                message: "“\(held.text)” goes to the agent as soon as this Cloud workspace has started."
            )
        } else if session.phase == .live {
            EmptyStateView(
                glyph: "bubble.left.and.bubble.right",
                title: "No chats yet",
                message: "Start a chat to give the agent in this Cloud workspace something to do.",
                actionTitle: session.allows("prompt") ? "New Chat" : nil,
                action: session.allows("prompt") ? { Task { await session.newChat() } } : nil
            )
        } else {
            Palette.windowBackground
        }
    }

    /// Whether the machine is still setting itself up, which is what a brand new workspace is doing
    /// for its first few minutes.
    private var isSettingUp: Bool { session.isRunningSetup }
}

/// Setup's output so far: what the machine ran after it was created, and after every wake.
struct CloudSetupLogView: View {
    var session: CloudWorkspaceSession
    @State private var hasRead = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Metrics.spacingWide) {
                Text(summary)
                    .fontWeight(.medium)
                Spacer()
                if session.allows("files") {
                    Button("Run Setup Again") {
                        Task { await session.run(.runSetup) }
                    }
                    .disabled(session.state.setup?.state == "running")
                }
            }
            .padding(Metrics.gutter)
            Divider()
            ScrollView {
                Text(session.state.setupLog.isEmpty ? "No setup output yet." : session.state.setupLog)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Metrics.gutter)
            }
            .defaultScrollAnchor(.bottom)
        }
        .task(id: session.phase == .live) {
            guard session.phase == .live, !hasRead else { return }
            hasRead = await session.readSetupOutput()
        }
    }

    private var summary: String {
        guard let setup = session.state.setup else { return "Setup" }
        switch setup.state {
        case "running": return "Setup is running" + (setup.step.map { ": \($0)" } ?? "")
        case "succeeded": return "Setup finished"
        case "failed": return "Setup failed"
        case "skipped": return "This project has no setup script"
        default: return "Setup has not started yet"
        }
    }
}
