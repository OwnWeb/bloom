import SwiftUI
import BloomCore

/// Ask Bloom given the whole centre column, reached from the panel's expand button.
///
/// Conversations share the app's tab chrome here, visible once a second one is open. The panel
/// lists the same conversations in a rail instead. See `AskPanelView`.
struct AskView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let isStripShown = app.ask.sessions.count > 1
        // The same split the centre column makes: each busy tab with a strip, the top edge
        // without one, never both. See `BusySignalPlacement`.
        let busy = BusySignalPlacement.resolve(
            isStripShown: isStripShown,
            tabs: app.ask.sessions.map(\.id),
            selected: app.ask.selectedID,
            isRunning: app.ask.isRunning
        )
        VStack(spacing: 0) {
            if isStripShown { AskTabStrip(busy: busy) }
            AskConversationContent()
        }
        .background(Palette.windowBackground)
        // A lone conversation has no tab to sweep, so its segment runs along the top edge, the
        // way a workspace's column does. `.identity`, so it leaves at once when the strip arrives.
        .overlay(alignment: .top) {
            if !isStripShown {
                ColumnBusySignal(isActive: busy.showsColumnTop).transition(.identity)
            }
        }
        // And VoiceOver hears it through the title bar, which says "Ask Bloom". See
        // `WindowTitleText.busySelection`.
        .onChange(of: busy.showsColumnTop, initial: true) { _, shows in
            WindowTitleText.shared.setBusy(shows, for: .ask)
        }
        .onDisappear { WindowTitleText.shared.setBusy(false, for: .ask) }
    }
}
