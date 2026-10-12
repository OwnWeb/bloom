import SwiftUI
import BloomCore

/// The line that opens a session.
///
/// The CLI reports what it started with as storage identifiers (`opus-5-1m`, `acceptEdits`), and
/// those are not words. They are shown the way the composer's own pickers show them, so the same
/// setting reads the same everywhere in the app.
struct SessionStartRowView: View {
    var info: AgentInit
    /// Carried by this row rather than a row of its own, so the model is not named twice.
    var route: ModelRouteNote?
    /// Nil where Change offers nothing. See `ModelRouteChangeMenu`.
    var routeChoices: [ModelRoute]?
    var onReroute: (ModelRoute) -> Void = { _ in }

    private var modelLabel: String {
        ComposerOption.label(
            for: info.model,
            in: ComposerModelCatalog.shared.options(for: .claudeCode) + ComposerOption.models
        )
    }

    /// In the backend's own words, because that is what the composer's menu says and a chip
    /// naming a row that is not in that menu sends the reader looking for it.
    private var permissionLabel: String {
        PermissionMode(rawValue: info.permissionMode)?.label(on: info.agentKind)
            ?? ComposerOption.titleCased(info.permissionMode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: TranscriptLayout.glyphGap) {
                TranscriptGlyph(symbol: "bolt.horizontal.circle")

                Text("Started with")
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
                    .transcriptLabelColumn("Started with", font: Typo.label)

                if !info.model.isEmpty {
                    Chip(text: modelLabel)
                }
                // The CLI does not report its starting effort, so it shows only where the router chose it.
                if let effort = route?.route.effort, !effort.isEmpty {
                    Chip(text: "\(ModelRouteCaption.effortLabel(effort)) effort")
                }
                if !info.permissionMode.isEmpty {
                    Chip(text: permissionLabel)
                }

                Spacer(minLength: 0)

                if let route, let routeChoices {
                    ModelRouteChangeMenu(current: route.route, choices: routeChoices, onChoose: onReroute)
                }
            }
            .transcriptRowFrame()

            // Below the one-line frame, because a wrapped reason inside it ran out of the row.
            if let route {
                Text(route.detail)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, TranscriptLayout.detailIndent)
                    .padding(.trailing, TranscriptLayout.inset)
            }
        }
    }
}
