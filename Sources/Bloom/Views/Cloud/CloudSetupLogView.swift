import BloomClient
import BloomCore
import SwiftUI

/// Setup's output so far: what the machine ran after it was created, and after every wake.
struct CloudSetupLogView: View {
    var session: CloudWorkspaceSession
    @State private var hasRead = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Metrics.spacingWide) {
                Text(summary)
                    .fontWeight(.medium)
                Spacer()
                if session.allows("files") {
                    Button("Run Setup Again") {
                        Task { await session.run(.runSetup) }
                    }
                    .disabled(session.state.setup?.state == "running")
                }
            }
            .padding(Metrics.gutter)
            Divider()
            ScrollView {
                Text(session.state.setupLog.isEmpty ? "No setup output yet." : session.state.setupLog)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Metrics.gutter)
            }
            .defaultScrollAnchor(.bottom)
        }
        .task(id: session.phase == .live) {
            guard session.phase == .live, !hasRead else { return }
            hasRead = await session.readSetupOutput()
        }
    }

    private var summary: String {
        guard let setup = session.state.setup else { return "Setup" }
        switch setup.state {
        case "running": return "Setup is running" + (setup.step.map { ": \($0)" } ?? "")
        case "succeeded": return "Setup finished"
        case "failed": return "Setup failed"
        case "skipped": return "This project has no setup script"
        default: return "Setup has not started yet"
        }
    }
}
