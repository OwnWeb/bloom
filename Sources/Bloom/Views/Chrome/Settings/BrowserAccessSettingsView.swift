import AppKit
import SwiftUI

/// Opt-in browser access to the current app instance. The access code lasts until Bloom quits or
/// the switch is turned off, so turning it off also revokes every open browser page.
struct BrowserAccessSettingsView: View {
    @Environment(AppModel.self) private var app

    private var enabled: Binding<Bool> {
        Binding(get: { app.localWebEnabled }, set: { app.setLocalWebEnabled($0) })
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: enabled) {
                    Text("Allow browser access")
                    Text("Browse conversations and send prompts while Bloom is running.")
                }
            } header: {
                Text("This Mac")
            } footer: {
                Text("Bloom runs the browser service on this Mac. Open it here without entering an address or code.")
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
                                    Text("Required when opening the address manually")
                                        .settingsFootnote()
                                    Spacer()
                                    Button("Copy Code") { copy(token) }
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
}
