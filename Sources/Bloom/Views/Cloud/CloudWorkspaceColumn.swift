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
        let session = app.cloud.session(for: id)
        VStack(spacing: 0) {
            CloudWorkspaceHeader(session: session, item: app.cloud.item(id))
            if let banner = CloudConnectionBanner.of(session.phase) {
                CloudBannerView(banner: banner) { session.wake() }
            }
            if let notice = session.notice {
                CloudNoticeStrip(text: notice) { session.notice = nil }
            }
            content(session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.windowBackground)
        .task(id: id) { session.open() }
    }

    @ViewBuilder
    private func content(_ session: CloudWorkspaceSession) -> some View {
        switch session.pane {
        case .chat:
            CloudChatArea(session: session)
        case .terminal:
            CloudTerminalPane(session: session)
        case .changes:
            CloudChangesPane(session: session)
        case .setup:
            CloudSetupLogView(session: session)
        }
    }
}

/// A connection banner: a line and, where the banner offers one, its button.
struct CloudBannerView: View {
    var banner: CloudConnectionBanner
    var onAction: () -> Void

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
            if let action = banner.action {
                Button(action, action: onAction)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, Metrics.inset)
        .background(Palette.windowBackground.opacity(0.6))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
    }
}

/// A command that failed where no dialog belongs, said once over the column until dismissed.
struct CloudNoticeStrip: View {
    var text: String
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacingWide) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(Palette.warning)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Metrics.gutter)
            Button("Dismiss", action: onDismiss)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, Metrics.spacingWide)
        .overlay(alignment: .bottom) { Divider() }
    }
}
