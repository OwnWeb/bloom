import AppKit
import BloomCore
import SwiftUI

/// Opt-in browser access to the current app instance. The access code lasts until Bloom quits or
/// the switch is turned off, so turning it off also revokes every open browser page.
struct BrowserAccessSettingsView: View {
    @Environment(AppModel.self) private var app

    private var isDevelopmentBrowser: Bool {
        Bundle.main.bundleIdentifier == Store.devBundleIdentifier
    }

    private var enabled: Binding<Bool> {
        Binding(get: { app.localWebEnabled }, set: { app.setLocalWebEnabled($0) })
    }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Bloom in your browser")
                            .font(.headline)
                        Text("Browser access is in beta. Some Mac features are still unavailable.")
                            .settingsFootnote()
                        Link("Setup instructions", destination: URL(string: "https://runbloom.app/browser-access")!)
                            .linkButton()
                    }
                    Spacer(minLength: 4)
                    betaStamp
                }
                .padding(.vertical, 8)
                .listRowBackground(Palette.questionWash)
            }

            Section {
                Toggle(isOn: enabled) {
                    Text("Allow browser access")
                    Text("Browse conversations and send prompts while Bloom is running.")
                }
            } header: {
                Text("This Mac")
            } footer: {
                Text(isDevelopmentBrowser
                     ? "Bloom Dev opens at its local address without a code on this Mac."
                     : "Bloom runs the browser service on this Mac. Open it here without entering an address or code.")
                    .settingsFootnote()
            }

            if app.localWebEnabled {
                Section("Connect") {
                    if let address = app.localWebAddress, let token = app.localWebToken {
                        Button("Open in Browser") {
                            app.openLocalWebInBrowser()
                        }
                        .buttonStyle(.borderedProminent)

                        DisclosureGroup("Manual connection") {
                            SettingsRow("Address") {
                                HStack {
                                    Text(address).font(Typo.codeSmall).textSelection(.enabled)
                                    Spacer()
                                    Button("Copy Address") { copy(address) }
                                }
                            }
                            SettingsRow("Access code") {
                                HStack {
                                    Text(isDevelopmentBrowser
                                         ? "Needed when connecting through another hostname"
                                         : "Required when opening the address manually")
                                        .settingsFootnote()
                                    Spacer()
                                    Button("Copy Code") { copy(token) }
                                }
                            }
                            if let port = URL(string: address)?.port {
                                SettingsRow("Tailscale") {
                                    Button("Copy Serve Command") {
                                        copy("tailscale serve --bg \(port)")
                                    }
                                }
                            }
                        }
                    } else if let error = app.localWebError {
                        Text("Could not start browser access: \(error)")
                            .foregroundStyle(.red)
                    } else {
                        Text("Starting browser access...")
                            .settingsFootnote()
                    }
                }
            }
        }
        .settingsForm()
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private var betaStamp: some View {
        VStack(spacing: 1) {
            Image(systemName: "sparkles")
                .font(.system(size: 17, weight: .medium))
            Text("BETA")
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .tracking(1.2)
        }
        .foregroundStyle(Palette.accent)
        .frame(width: 66, height: 66)
        .background(Palette.surface, in: Circle())
        .overlay {
            Circle()
                .strokeBorder(Palette.accent.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
        }
        .rotationEffect(.degrees(-9))
        .accessibilityHidden(true)
    }
}
