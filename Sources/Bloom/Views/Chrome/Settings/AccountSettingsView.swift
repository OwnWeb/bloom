import BloomClient
import BloomCore
import SwiftUI

/// The Bloom Account pane: signing in to runbloom.app, which Cloud workspaces need and nothing
/// else does.
///
/// **The signed out state is the explanation.** This is the one place the app says what an account
/// is for, so a signed out pane says it in two sentences and offers the button, rather than an empty
/// form with a sign in row that assumes the reader already knows.
///
/// Keys, secrets, projects and team members are managed on runbloom.app in phase 1, so the signed
/// in pane shows what is set (booleans only, since a key never leaves runbloom.app) and links there
/// for changing it.
struct AccountSettingsView: View {
    @Environment(AppModel.self) private var app

    private var cloud: CloudWorkspaces { app.cloud }

    var body: some View {
        Form {
            switch cloud.accountState {
            case .signedOut:
                signedOut
            case .signingIn:
                signingIn
            case .loading:
                Section {
                    ProgressView("Reading your account…")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .signedIn:
                if let account = cloud.account { signedIn(account) }
            case .failed(let message):
                failed(message)
            }
        }
        .settingsForm()
    }

    private var signedOut: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("Cloud workspaces run in the cloud instead of on this Mac. They keep working while your Mac sleeps, and your team can open them too.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Sign in with your Bloom account to create and open them. Everything else in Bloom works without an account.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Sign In…") { Task { await cloud.beginSignIn() } }
                    .padding(.top, 4)
            }
        } header: {
            Text("Bloom account")
        } footer: {
            originNote
        }
    }

    private var signingIn: some View {
        Section {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Finish signing in in the window that opened.")
                Spacer()
                Button("Cancel") { cloud.signIn.cancelSignIn() }
            }
        } header: {
            Text("Bloom account")
        }
    }

    private func failed(_ message: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if cloud.signIn.isSignedIn {
                        Button("Try Again") { Task { await cloud.refresh() } }
                        Button("Sign Out") { Task { await cloud.signOut() } }
                    } else {
                        Button("Sign In…") { Task { await cloud.beginSignIn() } }
                    }
                }
            }
        } header: {
            Text("Bloom account")
        } footer: {
            originNote
        }
    }

    @ViewBuilder
    private func signedIn(_ account: RunbloomAccount) -> some View {
        Section {
            SettingsRow {
                Text(account.email)
                    .foregroundStyle(.secondary)
            } label: {
                Text(account.name)
            }
            SettingsRow {
                Text(account.githubConnected ? "Connected" : "Not connected")
                    .foregroundStyle(account.githubConnected ? .primary : .secondary)
            } label: {
                Text("GitHub")
            }
        } header: {
            Text("Signed in")
        } footer: {
            if !account.githubConnected {
                Text("Connect GitHub on runbloom.app to prompt in a Cloud workspace. Pushes and pull requests are made as you.")
            }
        }

        ForEach(account.teams) { team in
            Section {
                if team.cloudWorkspacesEnabled {
                    ForEach(["claude", "codex"], id: \.self) { agent in
                        SettingsRow {
                            Text(keyDescription(account: account, team: team.id, agent: agent))
                                .foregroundStyle(account.hasAgentKey(team: team.id, agent: agent) ? .primary : .secondary)
                        } label: {
                            Text(agent == "claude" ? "Claude Code key" : "Codex key")
                        }
                    }
                } else {
                    Text("Cloud workspaces are not turned on for this team yet.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(team.name)
            }
        }

        Section {
            HStack {
                Button("Manage on runbloom.app") {
                    NSWorkspace.shared.open(cloud.environment.origin.appending(path: "account"))
                }
                Spacer()
                Button("Sign Out") { Task { await cloud.signOut() } }
            }
        } footer: {
            originNote
        }
    }

    private func keyDescription(account: RunbloomAccount, team: String, agent: String) -> String {
        guard let status = account.agentKeys.first(where: { $0.teamID == team && $0.agent == agent }) else { return "Not set" }
        switch (status.teamKey, status.personalKey) {
        case (true, true): return "Team key, and your own for workspaces you do not share"
        case (true, false): return "Team key"
        case (false, true): return "Your own key, in workspaces you do not share"
        case (false, false): return "Not set"
        }
    }

    /// Only said when this build talks to somewhere other than runbloom.app itself, which is a
    /// development server and worth being unmistakable about.
    @ViewBuilder
    private var originNote: some View {
        if cloud.environment.origin != RunbloomEnvironment.productionOrigin {
            Text("Signing in to \(cloud.environment.origin.absoluteString).")
        }
    }
}
