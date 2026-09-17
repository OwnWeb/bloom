import AppKit
import BloomClient
import BloomCore
import SwiftUI

/// A Cloud workspace in the centre column: its header, where its connection is, its panes, and
/// whichever pane is chosen.
///
/// Its own column rather than `CenterColumnView`, because that column is built around a worktree on
/// this Mac (its tabs are rows in this Mac's database, its terminals are local processes, its diff
/// is `git` run here) and a Cloud workspace has none of those. What it shares is what matters most:
/// a chat is the app's own `TranscriptView` and `ComposerView` over a `TranscriptModel`, so a
/// Cloud conversation reads, scrolls and answers exactly like a local one.
///
/// **Opening is waking.** Selecting the workspace opens its connection, which is what wakes a
/// sleeping machine, so nothing here opens one that nobody selected.
struct CloudWorkspaceColumn: View {
    var id: CloudWorkspaceID
    @Environment(AppModel.self) private var app
    /// The tab whose name field is open, owned here for the reason `CenterColumnView` owns the
    /// local one: Rename Tab has to open a field on a strip that is not drawn yet.
    @State private var renamingID: String?

    var body: some View {
        let item = app.cloud.item(id)
        if app.cloud.isSignedIn, item == nil, !app.cloud.items.isEmpty {
            // Archived from another Mac, or no longer shared with this account. The list is the
            // truth, and it no longer holds this one.
            CloudEmptyStateView(state: .missingWorkspace)
        } else if let item, !item.canOpen {
            CloudEmptyStateView(state: .privateWorkspace(ownerName: item.owner?.name))
        } else if app.cloud.isSignedIn, item != nil {
            workspace(app.cloud.session(for: id), item: item)
        } else {
            CloudEmptyStateView(state: app.cloud.nothingOpenState)
        }
    }

    @ViewBuilder
    private func workspace(_ session: CloudWorkspaceSession, item: CloudWorkspaceItem?) -> some View {
        VStack(spacing: 0) {
            if TabStripVisibility.isShown(tabCount: session.entries.count, isRenaming: renamingID != nil) {
                CloudTabStripView(session: session, renamingID: $renamingID)
            }
            if let banner = CloudConnectionBanner.of(session.phase) {
                CloudBannerView(banner: banner) { take($0, on: session) }
            }
            // What setup is doing, which is the only account of a machine's first few minutes and
            // the only way back from a setup that failed.
            if let banner = CloudConnectionBanner.ofSetup(
                session.state.setup, isWatching: session.isShowingSetup, canRunSetup: session.allows("files")
            ) {
                CloudBannerView(banner: banner) { take($0, on: session) }
            }
            if let notice = session.notice {
                CloudNoticeStrip(notice: notice, onOpenRunbloom: { openRunbloom(for: session) }) { session.notice = nil }
            }
            if let change = session.composerChange, change.chatID == session.selectedChatID?.rawValue {
                CloudNoticeStrip(text: "\(change.name) changed this chat's settings.") { session.acknowledgeComposerChange() }
            }
            content(session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.windowBackground)
        .task(id: id) {
            session.open()
            await app.cloud.markRead(id)
        }
        // A workspace nobody is looking at keeps what it read and lets go of its stream, which
        // would otherwise reconnect by itself after a dropped network and wake its machine.
        .onChange(of: id) { previous, _ in app.cloud.existingSession(for: previous)?.suspend() }
        .onDisappear { app.cloud.existingSession(for: id)?.suspend() }
    }

    /// What a banner's button does. Every one of them is a way forward rather than a repeat of what
    /// the app is already doing by itself.
    private func take(_ action: CloudConnectionBanner.Action, on session: CloudWorkspaceSession) {
        switch action {
        case .wake, .retry: session.wake()
        case .runbloom: openRunbloom(for: session)
        case .watchSetup: session.open(.setup)
        case .runSetupAgain:
            session.open(.setup)
            Task { await session.run(.runSetup) }
        }
    }

    /// runbloom.app, as close to the cause as the app can get: the team's own page when the account
    /// named one, and the account page otherwise.
    private func openRunbloom(for session: CloudWorkspaceSession) {
        NSWorkspace.shared.open(app.cloud.runbloomPage(forWorkspace: session.id))
    }

    @ViewBuilder
    private func content(_ session: CloudWorkspaceSession) -> some View {
        switch session.selectedTab {
        case .chat, .none:
            CloudChatArea(session: session)
        case .tool(let id):
            switch session.tabs.tools.first(where: { $0.id == id })?.kind {
            case .terminal: CloudTerminalPane(session: session)
            // The same file list the inspector column draws, over the same protocol. The diff
            // beside it becomes the local review pane in the next slice; until then it is the same
            // line view the local diff is drawn with.
            case .changes: CloudReviewTab(session: session)
            case .setup: CloudSetupLogView(session: session)
            case .notes, .none: CloudChatArea(session: session)
            }
        }
    }
}

/// A connection banner: a line and, where the banner offers one, its button.
struct CloudBannerView: View {
    var banner: CloudConnectionBanner
    var onAction: (CloudConnectionBanner.Action) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.gutter) {
            switch banner.tone {
            case .progress: ProgressView().controlSize(.small)
            case .caution: Image(systemName: "moon.zzz").foregroundStyle(Palette.warning)
            case .failure: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.negative)
            }
            VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                Text(banner.title).fontWeight(.medium)
                if let message = banner.message {
                    Text(message)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Metrics.gutter)
            ForEach(banner.actions, id: \.self) { action in
                Button(action.title) { onAction(action) }
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, Metrics.inset)
        .background(Palette.windowBackground.opacity(0.6))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
    }
}

/// A command that failed where no dialog belongs, said once over the column until dismissed, in the
/// words of whoever refused it and with the way back to where the cause is settled.
struct CloudNoticeStrip: View {
    var notice: CloudRefusalNotice
    var onOpenRunbloom: (() -> Void)?
    var onDismiss: () -> Void

    init(notice: CloudRefusalNotice, onOpenRunbloom: (() -> Void)? = nil, onDismiss: @escaping () -> Void) {
        self.notice = notice
        self.onOpenRunbloom = onOpenRunbloom
        self.onDismiss = onDismiss
    }

    init(text: String, onDismiss: @escaping () -> Void) {
        self.init(notice: CloudRefusalNotice(message: text, code: nil), onDismiss: onDismiss)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingWide) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(Palette.warning)
            Text(notice.sentence)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Metrics.gutter)
            if notice.opensRunbloom, let onOpenRunbloom {
                Button("Open runbloom.app", action: onOpenRunbloom)
                    .buttonStyle(.borderless)
            }
            Button("Dismiss", action: onDismiss)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, Metrics.spacingWide)
        .overlay(alignment: .bottom) { Divider() }
    }
}
