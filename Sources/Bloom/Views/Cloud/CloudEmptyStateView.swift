import AppKit
import BloomClient
import BloomCore
import SwiftUI

/// Where a Cloud workspace would be and there is none: a title, a sentence, the steps when there are
/// any, and one button that does the next thing.
///
/// Two sizes of the same words. The centre column gets the app's own `EmptyStateView`, which is what
/// every other empty pane in the window uses; the sidebar gets the compact one, because a section of
/// a source list has no room for a glyph and a paragraph. Which words they are is
/// `CloudEmptyState`'s, so the two cannot drift.
struct CloudEmptyStateView: View {
    var state: CloudEmptyState
    var isCompact = false
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if isCompact {
            compact
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

    private var compact: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingWide) {
            Text(state.title)
                .font(.callout.weight(.medium))
            Text(message)
                .font(.callout)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let action = state.action {
                Button(action.title) { take(action) }
                    .linkButton()
                    .font(.callout)
            }
        }
        .padding(.vertical, Metrics.spacingWide)
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
            NSWorkspace.shared.open(page ?? app.cloud.environment.origin.appending(path: "account"))
        case .createWorkspace:
            app.cloud.isCreating = true
        }
    }
}
