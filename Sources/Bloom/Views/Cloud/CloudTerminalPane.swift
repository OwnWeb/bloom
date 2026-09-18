import AppKit
import SwiftUI

/// The reader's terminal in a Cloud workspace.
struct CloudTerminalPane: View {
    var session: CloudWorkspaceSession

    var body: some View {
        let terminal = session.terminal
        VStack(spacing: 0) {
            switch terminal.state {
            case .ended(let reason):
                // "Ended" rather than "disconnected", because it does not come back: a machine
                // that restarts takes the shell, its command and its scrollback with it. What
                // typing gets is a new shell in the same workspace, and the pane says so.
                CloudNoticeStrip(
                    text: "This terminal ended\(reason.map { ": \($0)" } ?? "."). Type to start a new one."
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
            CloudTerminalHost(view: terminal.view)
                .padding(Metrics.spacingWide)
        }
        .onAppear { terminal.connect() }
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
