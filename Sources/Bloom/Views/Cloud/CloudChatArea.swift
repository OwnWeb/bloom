import AppKit
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
            CloudChatView(transcript: transcript, readiness: readiness(for: transcript)) {
                NSWorkspace.shared.open(app.cloud.runbloomPage(forWorkspace: session.id))
            }
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
                action: { session.pane = .setup }
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
    private var isSettingUp: Bool {
        ["pending", "running"].contains(session.state.setup?.state ?? "")
    }

    /// What this person is missing before a turn in this chat could start, from the account alone.
    private func readiness(for transcript: TranscriptModel) -> CloudPromptReadiness? {
        guard let teamID = app.cloud.item(session.id)?.teamID else { return nil }
        return CloudPromptReadiness(account: app.cloud.account, teamID: teamID, agent: transcript.session.agentKind.wireName)
    }
}

/// One Cloud chat: the app's own transcript and composer over a Cloud `TranscriptModel`, laid out
/// the way Ask Bloom lays out a chat with no worktree.
private struct CloudChatView: View {
    let transcript: TranscriptModel
    /// What is missing before a prompt here could start a turn, or nil when nothing is.
    var readiness: CloudPromptReadiness?
    var onOpenRunbloom: () -> Void
    @State private var isScrolledUp = false
    @State private var room = ComposerRoom()

    var body: some View {
        TranscriptView(transcript: transcript) { isScrolledUp = $0 }
            .environment(\.composerRoom, room)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                ComposerDock(showsJumpToNewest: isScrolledUp, onJumpToNewest: transcript.jumpToLiveEnd) {
                    VStack(spacing: Metrics.spacingWide) {
                        // Said before anything is typed, because runbloom.app would otherwise refuse
                        // the turn a minute later with the same sentence and nothing to press.
                        if let readiness {
                            HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingWide) {
                                Image(systemName: "exclamationmark.circle").foregroundStyle(Palette.warning)
                                Text(readiness.sentence)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: Metrics.spacingWide)
                                if readiness.opensRunbloom {
                                    Button("Open runbloom.app", action: onOpenRunbloom)
                                        .buttonStyle(.borderless)
                                }
                            }
                            .font(Typo.caption)
                            .padding(.horizontal, Metrics.gutter)
                        }
                        ComposerView(transcript: transcript, model: nil, room: room, placeholder: "Message the agent in this Cloud workspace")
                    }
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
