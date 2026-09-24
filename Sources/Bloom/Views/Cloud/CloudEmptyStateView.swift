import AppKit
import BloomClient
import BloomCore
import SwiftUI

/// Where a Cloud workspace would be and there is none: a title, a sentence, the steps when there are
/// any, and one button that does the next thing.
///
/// The centre column gets the app's own `EmptyStateView`. In the sidebar, a next step gets a
/// small invitation card; a state with no action stays a quiet line in the list.
struct CloudEmptyStateView: View {
    var state: CloudEmptyState
    var isCompact = false
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if isCompact {
            if let action = state.action {
                CloudSidebarInvitationCard(state: state) { take(action) }
            } else {
                compact
            }
        } else {
            EmptyStateView(
                glyph: glyph,
                title: state.title,
                message: message,
                actionTitle: state.action?.title,
                action: state.action.map { action in { take(action) } }
            )
        }
    }

    /// The account is still loading, so there is no next step to offer yet.
    private var compact: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            Text(state.title)
                .fontWeight(.medium)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Metrics.spacingSmall)
        .padding(.leading, SidebarMetrics.contentColumn)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// The steps read as part of the sentence rather than as a list, because the empty state's shape
    /// is one sentence and the sidebar's width is not a checklist's.
    private var message: String {
        ([state.sentence] + state.steps).joined(separator: " ")
    }

    private var glyph: String {
        switch state.action {
        case .signIn: "person.crop.circle"
        case .createWorkspace: "cloud"
        default: "exclamationmark.icloud"
        }
    }

    private func take(_ action: CloudEmptyState.Action) {
        switch action {
        case .signIn:
            SettingsTabRequest.post(.account)
            openSettings()
        case .open(let page, _):
            NSWorkspace.shared.open(page ?? app.cloud.environment.teamPage)
        case .createWorkspace:
            openWindow(id: CreateCloudWorkspaceWindow.id)
        }
    }
}

/// The signed-in Cloud section's next step, in the same still-water treatment the old sign-in
/// card used. The whole card is the button, so its short call to action does not need a separate
/// narrow row under a paragraph. The setup variant opens the team's page from runbloom.app.
struct CloudSidebarInvitationCard: View {
    var state: CloudEmptyState
    var action: () -> Void

    private var isSetup: Bool {
        if case .open = state.action { return true }
        return false
    }

    private var isEarlyAccess: Bool {
        state.title == "Bloom Cloud workspaces are in early access"
    }

    private var title: String {
        if isEarlyAccess { return "Bloom Cloud early access" }
        switch state.action {
        case .signIn: return "Sign in to Bloom Cloud"
        case .open: return "Complete Cloud setup"
        case .createWorkspace: return "Create a Cloud workspace"
        case nil: return state.title
        }
    }

    private var detail: String {
        if isEarlyAccess { return state.sentence }
        switch state.action {
        case .open: return state.steps.first ?? state.sentence
        case .createWorkspace: return "Give an agent its own machine in the cloud."
        case .signIn, nil: return state.sentence
        }
    }

    private var prompt: String {
        switch state.action {
        case .signIn: return "Sign in"
        case .open: return "Continue on runbloom.app"
        case .createWorkspace: return "Create workspace"
        case nil: return ""
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Metrics.spacingWide) {
                Image(nsImage: BloomIconArtwork.composite(size: 28) ?? Brand.mark)
                    .resizable()
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(Brand.foam)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Brand.foam.opacity(0.8))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Metrics.spacingSmall) {
                    Text(prompt)
                    Image(systemName: isSetup ? "arrow.up.right" : "arrow.right")
                        .accessibilityHidden(true)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.shallow)
                .padding(.top, Metrics.spacingSmall)
            }
            .padding(Metrics.spacingWide + Metrics.spacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    Brand.depth
                    CloudSettingsWaterStill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.vertical, Metrics.spacingSmall)
        .accessibilityLabel("\(title). \(detail). \(prompt)")
        .help(state.action?.title ?? prompt)
    }
}
