import SwiftUI
import BloomCore

/// The CLI owns authentication and displays its own browser links and prompts in a real terminal.
/// A completed command stays visible: cancelling login can leave the old account connected, so
/// neither a clean exit nor cached account details are enough to announce a successful switch.
struct AgentSignInSheet: View {
    struct Request: Identifiable {
        let id = UUID()
        let kind: AgentKind
        let executable: String
        let isSwitchingAccount: Bool
        let profile: AgentAccountProfile?
        let accountHome: String?
        let directory = AgentScratchDirectory.current()

        init(kind: AgentKind, executable: String, isSwitchingAccount: Bool,
             profile: AgentAccountProfile? = nil, accountHome: String? = nil) {
            self.kind = kind
            self.executable = executable
            self.isSwitchingAccount = isSwitchingAccount
            self.profile = profile
            self.accountHome = accountHome
        }
    }

    let request: Request
    let onExit: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var session: LoginTerminalSession?
    @State private var failure: String?
    @State private var exit: TerminalExit?

    private var wording: AgentSignInWording { AgentSignInWording(kind: request.kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            Text(request.profile.map { "Sign in to \($0.name)" }
                ?? wording.title)
                .font(Typo.heading)
                .foregroundStyle(Palette.textPrimary)

            Text(wording.intro)
                .font(Typo.label)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if request.isSwitchingAccount && request.profile == nil, let note = wording.switchingNote {
                Text(note)
                    .settingsFootnote()
            }

            if let session {
                VStack(spacing: 0) {
                    Text(session.label)
                        .font(Typo.codeSmall)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(session.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, InspectorLayout.inset)
                        .frame(height: InspectorLayout.barHeight)
                        .background(Palette.surfaceSunken)

                    Hairline()

                    LoginTerminal(session: session)
                        .frame(height: 280)
                }
                .clipShape(RoundedRectangle(cornerRadius: Metrics.corner))
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.corner)
                        .strokeBorder(Palette.border, lineWidth: Metrics.outline)
                )
            }

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(Typo.label)
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if exit != nil {
                Text(wording.finished)
                    .font(Typo.label)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Metrics.gutter) {
                if request.profile == nil {
                    Button(wording.copyCommand) {
                        Clipboard.copy(TerminalLaunchScript.shellCommand(
                            directory: request.directory,
                            executable: request.executable,
                            arguments: request.kind.loginArguments
                        ))
                    }
                    .help(wording.copyHelp)
                }

                Spacer()

                if failure != nil || exit != nil {
                    Button("Try again", action: start)
                }

                Button(session?.isRunning == true ? "Cancel" : "Done") {
                    session?.stop()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Metrics.pane)
        .frame(width: 660)
        .background(Palette.surface)
        .task { start() }
        .onDisappear { session?.stop() }
    }

    private func start() {
        session?.stop()
        exit = nil
        failure = nil
        session = LoginTerminalSession(
            executable: request.executable,
            arguments: request.kind.loginArguments,
            directory: request.directory,
            environment: AgentAccountEnvironment.applying(
                kind: request.kind, home: request.accountHome, to: Shell.environment()
            ),
            onExit: { result in
                exit = result
                if result != .exited(0) {
                    failure = wording.unfinished
                }
                onExit()
            }
        )
        if session == nil {
            failure = "The \(request.kind.label) executable is no longer available. Check its path in Settings."
        }
    }
}
