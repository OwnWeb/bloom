import AppKit
import BloomClient
import BloomCore
import SwiftUI

/// Settings, Bloom Cloud: signing in to runbloom.app, what Bloom Cloud is for, and the account
/// once there is one.
///
/// **An invitation before it is a form.** It was a grouped form that said what Bloom Cloud is in
/// two sentences over a Sign In button, and the owner found it plain beside everything else Bloom
/// Cloud has become. So it opens on the brand's own ground, the deep water the About and welcome
/// windows stand on, with the mark and the name on it and the water breathing behind them, and
/// says what signing in buys in four lines, each of them checked against what Bloom Cloud actually
/// does today. Signed in, the same ground heads the account, its teams and the one agent setting.
///
/// **Drawn in SwiftUI throughout**, with the pane as a value (`CloudSettingsPane`) and this view
/// only reading the app into it. That is what lets `CloudSettingsGallery` photograph the real pane
/// offscreen: `ImageRenderer` draws SwiftUI and draws an AppKit-backed control as a placeholder,
/// so the few controls here go through one switch the gallery flips to drawn stand-ins.
struct CloudSettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(CloudWorkspaceStartTool.settingKey) private var agentsCreateCloudWorkspaces = false
    // On when absent, as `CloudWorkspaceStartQuestion.asks` reads it: each one costs money.
    @AppStorage(CloudWorkspaceStartQuestion.settingKey) private var asksBeforeCloudWorkspaceStart = true

    private var cloud: CloudWorkspaces { app.cloud }

    var body: some View {
        ScrollView {
            CloudSettingsPane(
                phase: phase,
                environment: cloud.environment,
                agentsCreateCloudWorkspaces: $agentsCreateCloudWorkspaces,
                asksBeforeCloudWorkspaceStart: $asksBeforeCloudWorkspaceStart,
                drawing: .live,
                actions: CloudSettingsPane.Actions(
                    signIn: { Task { await cloud.beginSignIn() } },
                    cancelSignIn: { cloud.signIn.cancelSignIn() },
                    retry: { Task { await cloud.refresh() } },
                    signOut: { Task { await cloud.signOut() } },
                    open: { NSWorkspace.shared.open($0) }
                )
            )
        }
        .scrollContentBackground(.hidden)
    }

    private var phase: CloudSettingsPane.Phase {
        switch cloud.accountState {
        case .signedOut: return .signedOut
        case .signingIn: return .signingIn
        case .loading: return .loading
        case .signedIn:
            guard let account = cloud.account else { return .loading }
            return .signedIn(account)
        case .failed(let message): return .failed(message, isSignedIn: cloud.signIn.isSignedIn)
        }
    }
}

/// The pane itself, as a value. See `CloudSettingsView`.
struct CloudSettingsPane: View {
    enum Phase {
        case signedOut
        case signingIn
        case loading
        /// Could not read the account. `isSignedIn` is whether there is a sign in to try again with.
        case failed(String, isSignedIn: Bool)
        case signedIn(RunbloomAccount)
    }

    /// Whether the controls are AppKit's, or drawn for a photograph. See `CloudSettingsGallery`.
    enum Drawing { case live, drawn }

    struct Actions {
        var signIn: @MainActor () -> Void = {}
        var cancelSignIn: @MainActor () -> Void = {}
        var retry: @MainActor () -> Void = {}
        var signOut: @MainActor () -> Void = {}
        var open: @MainActor (URL) -> Void = { _ in }
    }

    var phase: Phase
    var environment: RunbloomEnvironment
    @Binding var agentsCreateCloudWorkspaces: Bool
    @Binding var asksBeforeCloudWorkspaceStart: Bool
    var drawing: Drawing
    var actions: Actions
    /// The mark in the hero. Nil is this app's own icon; the gallery passes one, because the
    /// probe bundle it runs in has no compiled icon of its own.
    var mark: NSImage?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glows = false

    private static let corner: CGFloat = 12
    private static let heroHeight: CGFloat = 148

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter + Metrics.spacingWide) {
            hero
            switch phase {
            case .signedOut:
                benefits
                signInCard
            case .signingIn:
                card {
                    HStack(spacing: Metrics.spacingWide) {
                        spinner
                        Text("Finish signing in in the browser window that opened.")
                            .foregroundStyle(Palette.textSecondary)
                        Spacer(minLength: Metrics.spacing)
                        button("Cancel", action: actions.cancelSignIn)
                    }
                }
            case .loading:
                card {
                    HStack(spacing: Metrics.spacingWide) {
                        spinner
                        Text("Reading your account…").foregroundStyle(Palette.textSecondary)
                    }
                }
            case .failed(let message, let isSignedIn):
                card {
                    VStack(alignment: .leading, spacing: Metrics.spacingWide) {
                        Text(message).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: Metrics.spacing) {
                            if isSignedIn {
                                button("Try Again", prominent: true, action: actions.retry)
                                button("Sign Out", action: actions.signOut)
                            } else {
                                button("Sign In…", prominent: true, action: actions.signIn)
                            }
                        }
                    }
                }
            case .signedIn(let account):
                signedIn(account)
            }
            originNote
        }
        .padding(Metrics.gutter + Metrics.spacingWide)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - The hero

    /// The brand's plinth, as the About window draws it: Depth with the water breathing in it, the
    /// mark on a shadow, and the name in the display serif. The one addition is a slow glow behind
    /// the mark, the runbloom.app gate's own "alive, not animated" breath, which stops for Reduce
    /// Motion like the water does.
    private var hero: some View {
        ZStack(alignment: .leading) {
            ZStack {
                Brand.depth
                water
            }
            HStack(spacing: Metrics.gutter) {
                Image(nsImage: mark ?? NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .shadow(color: .black.opacity(0.55), radius: 12, y: 7)
                    // Behind the mark and outside its layout, so the glow widens nothing.
                    .background {
                        Circle()
                            .fill(Brand.shallow)
                            .frame(width: 84, height: 84)
                            .blur(radius: 26)
                            .opacity(glows ? 0.55 : 0.25)
                    }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                    Text(verbatim: "Bloom Cloud")
                        .font(Typo.display)
                        .tracking(Typo.displayTracking)
                        .foregroundStyle(Brand.foam)
                        .accessibilityAddTraits(.isHeader)
                    Text("Your agents, on machines of their own.")
                        .font(Typo.body)
                        .foregroundStyle(Brand.mistDim)
                }
            }
            .padding(.horizontal, Metrics.gutter + Metrics.spacingWide + Metrics.spacingWide)
        }
        .frame(height: Self.heroHeight)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .onAppear {
            guard drawing == .live, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 3.5).repeatForever(autoreverses: true)) { glows = true }
        }
    }

    @ViewBuilder
    private var water: some View {
        switch drawing {
        case .live: BrandWater()
        case .drawn: CloudSettingsWaterStill()
        }
    }

    // MARK: - Signed out

    /// What signing in buys, four lines, each true of Bloom Cloud as it is today. Checked against
    /// the code when written: a workspace is a machine of its own (`CloudWorkspaces.create`), a
    /// shared one is opened, watched and messaged by the team (`CloudSharing`, presence, messages
    /// addressed to a person), runbloom.app creates and opens them in a browser and lays itself out
    /// for a phone, and nothing in this Mac's own workspaces is sent to runbloom.app: its agents
    /// talk to their own providers, as they always did, and only a Bloom Cloud workspace runs
    /// there.
    private var benefits: some View {
        Grid(horizontalSpacing: Metrics.gutter, verticalSpacing: Metrics.gutter) {
            GridRow {
                benefit("moon.zzz", "Keeps going while your Mac sleeps",
                        "Each workspace runs on a machine of its own, so a long task finishes with the lid closed.")
                benefit("person.2", "Your team, in the same workspace",
                        "Share one and colleagues can open it, watch the agent work and message you there.")
            }
            GridRow {
                benefit("iphone", "Start from anywhere",
                        "Create and follow them on runbloom.app, in a browser or on your phone.")
                benefit("lock.laptopcomputer", "This Mac's workspaces stay here",
                        "Nothing in them goes to runbloom.app. Only what you create in Bloom Cloud runs there.")
            }
        }
    }

    private func benefit(_ symbol: String, _ title: String, _ sentence: String) -> some View {
        HStack(alignment: .top, spacing: Metrics.spacingWide) {
            Image(systemName: symbol)
                .font(Typo.title)
                .foregroundStyle(Palette.accent)
                .frame(width: 30, height: 30)
                .background(Palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Metrics.spacingHair) {
                Text(title).font(Typo.title).foregroundStyle(Palette.textPrimary)
                Text(sentence)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    private var signInCard: some View {
        card {
            HStack(spacing: Metrics.gutter) {
                VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                    Text("Sign in with your Bloom account").font(Typo.title)
                    Text("Everything else in Bloom works without one.")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer(minLength: Metrics.spacing)
                button("Sign In…", prominent: true, action: actions.signIn)
            }
        }
    }

    // MARK: - Signed in

    @ViewBuilder
    private func signedIn(_ account: RunbloomAccount) -> some View {
        card {
            HStack(spacing: Metrics.spacingWide + Metrics.spacingSmall) {
                initials(account.name)
                VStack(alignment: .leading, spacing: Metrics.spacingHair) {
                    Text(account.name).font(Typo.title)
                    Text(account.email).font(Typo.caption).foregroundStyle(Palette.textSecondary)
                }
                Spacer(minLength: Metrics.spacing)
                github(account)
            }
            if !account.githubConnected {
                Text("Connect GitHub on runbloom.app to prompt in a Bloom Cloud workspace. Pushes and pull requests are made as you.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Metrics.spacingWide)
            }
        }

        if !account.teams.isEmpty {
            sectionHeading(account.teams.count == 1 ? "Team" : "Teams")
            ForEach(account.teams) { team in
                teamCard(team, account: account)
            }
        }

        sectionHeading("Agents")
        card {
            HStack(alignment: .top, spacing: Metrics.gutter) {
                VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                    Text(CloudWorkspaceStartTool.settingTitle).font(Typo.title)
                    // Plain words, which is what a settings pane owes somebody. That this is a
                    // preference Bloom keeps rather than a gate runbloom.app enforces is said in
                    // docs/BRIDGE.md, where it belongs. No promise that you are asked first: a chat
                    // that bypasses permissions asks nobody. See `CloudWorkspaceStartTool`.
                    Text("Each Bloom Cloud workspace is its own machine and costs money. When this is on, your agents may start one.")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                toggle($agentsCreateCloudWorkspaces, label: CloudWorkspaceStartTool.settingTitle)
            }
            Divider().padding(.vertical, Metrics.gutter)
            HStack(alignment: .top, spacing: Metrics.gutter) {
                VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                    Text(CloudWorkspaceStartQuestion.settingTitle).font(Typo.title)
                    // A promise this time, and a true one: Bloom asks in its own window, so the
                    // chat's permission mode does not come into it. See `CloudWorkspaceStartQuestion`.
                    Text("Bloom shows you what the agent wants to create and waits for your answer, whatever the chat's permission mode. When this is off, the switch above decides alone.")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                toggle($asksBeforeCloudWorkspaceStart, label: CloudWorkspaceStartQuestion.settingTitle)
            }
            // Meaningless while agents may not create any, so it steps back rather than going.
            .disabled(!agentsCreateCloudWorkspaces)
            .opacity(agentsCreateCloudWorkspaces ? 1 : 0.5)
        }

        HStack(spacing: Metrics.spacing) {
            button("Open runbloom.app") { actions.open(environment.accountPage) }
            Spacer()
            button("Sign Out", action: actions.signOut)
        }
    }

    private func initials(_ name: String) -> some View {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        return Text(letters.isEmpty ? "?" : letters.uppercased())
            .font(Typo.title)
            .foregroundStyle(Brand.foam)
            .frame(width: 40, height: 40)
            .background(Brand.depth, in: Circle())
            .accessibilityHidden(true)
    }

    private func github(_ account: RunbloomAccount) -> some View {
        Label(
            account.githubConnected ? (account.githubLogin.map { "GitHub: \($0)" } ?? "GitHub connected") : "GitHub not connected",
            systemImage: account.githubConnected ? "checkmark.circle.fill" : "exclamationmark.circle"
        )
        .font(Typo.caption)
        .foregroundStyle(account.githubConnected ? Palette.positive : Palette.warning)
    }

    private func teamCard(_ team: RunbloomTeam, account: RunbloomAccount) -> some View {
        card {
            HStack(spacing: Metrics.spacing) {
                Text(team.name).font(Typo.title)
                Text(team.role.capitalizedFirst)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, Metrics.spacingSmall + 2)
                    .padding(.vertical, 1)
                    .background(Palette.textSecondary.opacity(0.12), in: Capsule())
                Spacer()
                if team.cloudWorkspacesEnabled, TeamSetupNotice(team: team, environment: environment) == nil {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.positive)
                }
            }
            if let notice = TeamSetupNotice(team: team, environment: environment) {
                VStack(alignment: .leading, spacing: Metrics.spacingWide) {
                    Text(notice.sentence)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(notice.steps, id: \.self) { step in
                        Label {
                            Text(step).font(Typo.caption).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "circle").foregroundStyle(Palette.textTertiary)
                        }
                    }
                    button(notice.buttonTitle) { actions.open(notice.page ?? environment.teamPage) }
                }
                .padding(.top, Metrics.spacingWide)
            } else if team.cloudWorkspacesEnabled {
                VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                    keyRow("Claude Code key", account: account, team: team.id, agent: "claude")
                    keyRow("Codex key", account: account, team: team.id, agent: "codex")
                }
                .padding(.top, Metrics.spacingWide)
            }
        }
    }

    private func keyRow(_ title: String, account: RunbloomAccount, team: String, agent: String) -> some View {
        HStack {
            Text(title).font(Typo.caption)
            Spacer()
            Text(Self.keyDescription(account: account, team: team, agent: agent))
                .font(Typo.caption)
                .foregroundStyle(account.hasAgentKey(team: team, agent: agent) ? Palette.textPrimary : Palette.textTertiary)
        }
    }

    static func keyDescription(account: RunbloomAccount, team: String, agent: String) -> String {
        guard let status = account.agentKeys.first(where: { $0.teamID == team && $0.agent == agent }) else { return "Not set" }
        switch (status.teamKey, status.personalKey) {
        case (true, true): return "Team key, and your own for workspaces you do not share"
        case (true, false): return "Team key"
        case (false, true): return "Your own key, in workspaces you do not share"
        case (false, false): return "Not set"
        }
    }

    // MARK: - Pieces

    private func sectionHeading(_ text: String) -> some View {
        Text(text)
            .font(Typo.captionEmphasis)
            .foregroundStyle(Palette.textSecondary)
            .padding(.bottom, -Metrics.spacingWide)
            .accessibilityAddTraits(.isHeader)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .padding(Metrics.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Self.corner, style: .continuous).strokeBorder(Palette.border, lineWidth: Metrics.hairline))
    }

    /// Only said when this build talks to somewhere other than runbloom.app itself, which is a
    /// development server and worth being unmistakable about.
    @ViewBuilder
    private var originNote: some View {
        if environment.origin != RunbloomEnvironment.productionOrigin {
            Text("Signing in to \(environment.origin.absoluteString).")
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
        }
    }

    // MARK: - Controls, live or drawn

    @ViewBuilder
    private var spinner: some View {
        switch drawing {
        case .live: ProgressView().controlSize(.small)
        case .drawn: Circle().trim(from: 0, to: 0.7).stroke(Palette.textTertiary, lineWidth: 2).frame(width: 14, height: 14)
        }
    }

    @ViewBuilder
    private func button(_ title: String, prominent: Bool = false, action: @escaping @MainActor () -> Void) -> some View {
        switch drawing {
        case .live:
            if prominent {
                Button(title, action: action).buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                Button(title, action: action).buttonStyle(.bordered)
            }
        case .drawn:
            Text(title)
                .font(prominent ? Typo.title : Typo.label)
                .foregroundStyle(prominent ? Color.white : Palette.textPrimary)
                .padding(.horizontal, prominent ? 16 : 10)
                .padding(.vertical, prominent ? 7 : 4)
                .background(prominent ? Palette.controlAccent : Palette.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(prominent ? Color.clear : Palette.border))
        }
    }

    @ViewBuilder
    private func toggle(_ isOn: Binding<Bool>, label: String) -> some View {
        switch drawing {
        case .live:
            Toggle(label, isOn: isOn).toggleStyle(.switch).labelsHidden()
        case .drawn:
            Capsule()
                .fill(isOn.wrappedValue ? Palette.controlAccent : Palette.border)
                .frame(width: 34, height: 20)
                .overlay(alignment: isOn.wrappedValue ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 16, height: 16).padding(2)
                }
        }
    }
}

/// The water, held still, for a photograph of the pane. `BrandWater` is Core Animation layers,
/// which `ImageRenderer` does not draw; this is its two pools at rest, so the gallery shows the
/// ground the live pane stands on rather than a flat gradient.
struct CloudSettingsWaterStill: View {
    var body: some View {
        ZStack {
            RadialGradient(colors: [Brand.shallow.opacity(0.22), .clear], center: UnitPoint(x: 0.2, y: 0.1), startRadius: 0, endRadius: 260)
            RadialGradient(colors: [Color(nsColor: NSColor(rgb: 0x2AA3B4)).opacity(0.2), .clear], center: UnitPoint(x: 0.85, y: 0.9), startRadius: 0, endRadius: 300)
        }
    }
}
