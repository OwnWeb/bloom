import BloomCore
import SwiftUI

/// The chat pane of a Cloud workspace: the selected chat's transcript and composer, or what to do
/// when there is no chat yet.
struct CloudChatArea: View {
    var session: CloudWorkspaceSession

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
            CloudChatView(transcript: transcript)
                .id(id)
        } else if session.selectedChatID != nil {
            Palette.windowBackground
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
}

/// One Cloud chat: the app's own transcript and composer over a Cloud `TranscriptModel`, laid out
/// the way Ask Bloom lays out a chat with no worktree.
private struct CloudChatView: View {
    let transcript: TranscriptModel
    @State private var isScrolledUp = false
    @State private var room = ComposerRoom()

    var body: some View {
        TranscriptView(transcript: transcript) { isScrolledUp = $0 }
            .environment(\.composerRoom, room)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                ComposerDock(showsJumpToNewest: isScrolledUp, onJumpToNewest: transcript.jumpToLiveEnd) {
                    ComposerView(transcript: transcript, model: nil, room: room, placeholder: "Message the agent in this Cloud workspace")
                }
            }
            .onGeometryChange(for: CGFloat.self) { PaneMeasure.room($0.size.height) } action: {
                room.height = $0
            }
    }
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
