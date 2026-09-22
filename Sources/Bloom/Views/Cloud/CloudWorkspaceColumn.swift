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
            if let banner = shown(CloudConnectionBanner.of(session.phase, isBuilding: session.setupProgress != nil), on: session) {
                CloudBannerView(banner: banner, onDismiss: { app.cloud.dismiss(banner, for: session.id) }) {
                    take($0, on: session)
                }
            }
            // What runbloom.app currently needs to say about the workspace. Below the connection
            // because nothing can be read at all until that is up.
            if let banner = shown(CloudConnectionBanner.ofWorkspaceNotice(item?.workspaceNotice), on: session) {
                CloudBannerView(banner: banner, onDismiss: { app.cloud.dismiss(banner, for: session.id) }) {
                    take($0, on: session)
                }
            }
            if let notice = session.notice {
                CloudNoticeStrip(notice: notice, onOpenRunbloom: { openRunbloom(for: session) }) { session.notice = nil }
            }
            if let change = session.composerChange, change.chatID == session.selectedChatID?.rawValue {
                CloudNoticeStrip(text: "\(change.name) changed this chat's settings.") { session.acknowledgeComposerChange() }
            }
            // The app's own centre column: the same strip, the same panes, the same splits, the
            // same `+`. What a tool tab of this workspace draws is the one thing that differs, and
            // the workspace hands that back itself. See `WorkspaceSurface.toolPane`.
            CenterColumnView(model: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.windowBackground)
        // A workspace nobody is looking at keeps what it read and lets go of its stream, which
        // would otherwise reconnect by itself after a dropped network and wake its machine.
        // Opening it, and the rename field the menu bar opens, are `CenterColumnView`'s now.
        .onChange(of: id) { previous, _ in
            app.cloud.existingSession(for: previous)?.suspend()
        }
        .onDisappear { app.cloud.existingSession(for: id)?.suspend() }
    }

    /// The banner, unless this reader has put this one away. Only a banner that is a state rather
    /// than a blocker can be put away at all: see `CloudConnectionBanner.dismissalKey`.
    private func shown(_ banner: CloudConnectionBanner?, on session: CloudWorkspaceSession) -> CloudConnectionBanner? {
        guard let banner, !app.cloud.dismissedBanners.isDismissed(banner, workspaceID: session.id.rawValue) else { return nil }
        return banner
    }

    /// What a banner's button does. Every one of them is a way forward rather than a repeat of what
    /// the app is already doing by itself.
    private func take(_ action: CloudConnectionBanner.Action, on session: CloudWorkspaceSession) {
        switch action {
        case .wake, .retry: session.wake()
        // Announced, because this is the one where Bloom is already asking and the screen would
        // otherwise show nothing at all for the press. See `WorkspaceConnection.resume(announcing:)`.
        case .askNow: session.wake(announcing: true)
        case .runbloom: openRunbloom(for: session)
        }
    }

    /// runbloom.app, as close to the cause as the app can get: the team's own page when the account
    /// named one, and the current team's page otherwise.
    private func openRunbloom(for session: CloudWorkspaceSession) {
        NSWorkspace.shared.open(app.cloud.runbloomPage(forWorkspace: session.id))
    }

}

/// A connection banner: a line and, where the banner offers one, its button.
struct CloudBannerView: View {
    var banner: CloudConnectionBanner
    /// Closes this banner for this workspace, and is drawn only where closing it means something.
    /// A banner that is a state can be put away; one that is a blocker cannot. See
    /// `CloudConnectionBanner.dismissalKey`.
    var onDismiss: () -> Void = {}
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
            if banner.dismissalKey != nil {
                Button("Dismiss", systemImage: "xmark", action: onDismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(Palette.textTertiary)
                    .help("Hide this until it happens again. The Setup tab keeps the whole of it.")
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
