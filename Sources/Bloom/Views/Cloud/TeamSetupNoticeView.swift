import AppKit
import BloomClient
import SwiftUI

/// What a team still needs before it can create Cloud workspaces, and the way to it, said the same
/// way in the create sheet and in Settings rather than ending at "not turned on".
struct TeamSetupNoticeView: View {
    var notice: TeamSetupNotice

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingWide) {
            Text(notice.sentence)
                .fixedSize(horizontal: false, vertical: true)
            if !notice.steps.isEmpty {
                VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                    ForEach(notice.steps, id: \.self) { step in
                        Label {
                            Text(step).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "circle")
                                .foregroundStyle(Palette.textTertiary)
                        }
                    }
                }
            }
            if let page = notice.setupPage {
                Button(TeamSetupNotice.buttonTitle) { NSWorkspace.shared.open(page) }
            }
        }
    }
}
