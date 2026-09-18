import AppKit
import SwiftUI

/// The reader's terminal in a Cloud workspace.
struct CloudTerminalPane: View {
    var session: CloudWorkspaceSession

    var body: some View {
        let terminal = session.terminal
        VStack(spacing: 0) {
            switch terminal.state {
            case .dropped(let reason):
                // What is said is the connection stopping, because that is the whole of what this
                // Mac knows. The shell behind it survives a socket that disappears and does not
                // survive the workspace restarting, and one closed socket looks the same either
                // way: see `CloudTerminal.State.dropped`. Reconnecting answers it, since the
                // machine redraws the pane as it stands.
                CloudNoticeStrip(
                    text: "This terminal disconnected\(reason.map { ": \($0)" } ?? "."). Type to reconnect."
                ) {
                    terminal.connect()
                }
            case .refused(let reason):
                CloudNoticeStrip(text: reason) { terminal.retry() }
            case .connecting:
                HStack(spacing: Metrics.spacingWide) {
                    ProgressView().controlSize(.small)
                    Text("Connecting the terminal…").foregroundStyle(Palette.textSecondary)
                    Spacer()
                }
                .padding(Metrics.spacingWide)
            case .idle, .connected:
                EmptyView()
            }
            // **No inset, so the terminal's own ground reaches all four edges of the pane.** It
            // had eight points all round, and what showed through them was the pane behind it: a
            // cream terminal sitting on a white page like a card, rather than the pane being a
            // terminal. The local pane keeps four points because its panes can be split and a
            // prompt flush against a divider reads as broken; a Cloud workspace has one terminal
            // and no divider to sit against. See `TerminalSplitView.paneInset`.
            CloudTerminalHost(view: terminal.view)
        }
        .onAppear {
            terminal.connect()
            // The look is read on the way in as well as at build time, so a scheme or a font
            // changed in Settings while this pane was closed is what it comes back drawing.
            terminal.view.applyLook()
        }
    }
}

private struct CloudTerminalHost: NSViewRepresentable {
    let view: CloudTerminalView

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        attach(to: host)
        return host
    }

    func updateNSView(_ host: NSView, context: Context) {
        if view.superview !== host { attach(to: host) }
    }

    private func attach(to host: NSView) {
        view.removeFromSuperview()
        view.frame = host.bounds
        view.autoresizingMask = [.width, .height]
        host.addSubview(view)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }
}
