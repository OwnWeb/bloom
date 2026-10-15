import SwiftUI
import BloomCore

/// Settings ▸ Passwords: whether 1Password's Safari extension runs in browser tabs.
///
/// The line under the switch is where loading has got to rather than a description, because the
/// ways this can fail (not installed, would not load) are things only this pane can tell somebody.
///
/// The switch is bound to `BrowserExtensionHost` rather than to `@AppStorage`, so the setting has
/// one reader. Two readers of one key agree until somebody changes how one of them reads it.
struct PasswordSettingsView: View {
    @State private var host = BrowserExtensionHost.shared

    var body: some View {
        Form {
            Section {
                Toggle("Use 1Password in browser tabs", isOn: Binding(
                    get: { host.isEnabled },
                    set: { host.setEnabled($0) }
                ))
                .help("Loads the 1Password for Safari extension into Bloom's browser tabs.")
            } header: {
                Text("Password manager")
            } footer: {
                Text(host.status.footnote(isOn: host.isEnabled))
                    .settingsFootnote()
            }
        }
        .settingsForm()
        .onAppear { host.startIfNeeded() }
    }
}
