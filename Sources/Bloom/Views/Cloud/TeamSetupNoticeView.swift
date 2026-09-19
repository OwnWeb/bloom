import AppKit
import BloomClient
import SwiftUI

/// What a team still needs before it can create Cloud workspaces, and the way to it, said the same
/// way in the create sheet and in Settings rather than ending at "not turned on".
struct TeamSetupNoticeView: View {
    var notice: TeamSetupNotice
    /// Where runbloom.app is, for the fallback page when the notice named none.
    var environment: RunbloomEnvironment

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
            // The button names the first step still to take rather than "finish setting up", which
            // over four different steps says nothing about which one this is.
            Button(notice.buttonTitle) {
                NSWorkspace.shared.open(notice.page ?? environment.teamPage)
            }
        }
    }
}
