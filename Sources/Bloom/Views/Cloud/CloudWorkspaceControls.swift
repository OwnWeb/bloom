import BloomClient
import BloomCore
import BloomProtocol
import SwiftUI

/// The controls a Cloud workspace has that a local one does not: who else is here, the preview,
/// and sharing.
///
/// **There is no header bar any more.** A Cloud workspace's name is the window's title, its branch
/// and its pull request are the title bar's band, and its `+` is the toolbar's, exactly as a local
/// workspace's are; a bar of its own above the tabs was the largest thing that made a Cloud
/// workspace feel like a different app. What is left is what a local workspace has no answer to,
/// and it sits in the toolbar where a workspace's own controls sit.
struct CloudWorkspaceControls: ToolbarContent {
    var session: CloudWorkspaceSession
    var item: CloudWorkspaceItem?
    @Environment(AppModel.self) private var app
    @Binding var isSharing: Bool
    @Binding var isShowingPorts: Bool
    var ports: CloudPorts

    /// Everybody with the workspace open but the reader.
    private var others: [PresenceRecord] {
        session.state.presence.filter { $0.userID != session.readerID }
    }

    var body: some ToolbarContent {
        if !others.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                CloudPresenceView(people: others)
            }
        }
        // Beside Preview, because Preview is this feature with one port hard-coded: it opens the
        // project's own app and nothing else. A forward is the same reach without that
        // restriction, so the two belong together rather than in different corners of the window.
        ToolbarItem(placement: .primaryAction) {
            Button { isShowingPorts.toggle() } label: {
                Label { Text("Ports") } icon: { CloudPortsIcon(isForwarding: ports.hasLiveForward) }
            }
                .help("Reach a port inside this Bloom Cloud workspace from this Mac")
                .accessibilityValue(ports.hasLiveForward ? "Forwarding" : "Nothing forwarded")
                .popover(isPresented: $isShowingPorts, arrowEdge: .bottom) {
                    CloudPortsPopover(ports: ports)
                }
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Preview", systemImage: "safari") {
                Task { await session.openPreview() }
            }
            .help(
                session.capabilities.has(.preview)
                    ? "Open the project's app in your browser"
                    : WorkspaceCapabilities.Capability.preview.cloudSentence
            )
            .disabled(!session.capabilities.has(.preview))
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Share", systemImage: "person.2") { isSharing = true }
                .help(
                    item?.role == "owner"
                        ? "Share this Bloom Cloud workspace"
                        : "Only the person who made this Bloom Cloud workspace can share it."
                )
                .disabled(item?.role != "owner")
                .popover(isPresented: $isSharing, arrowEdge: .bottom) {
                    CloudSharePopover(workspaceID: session.id, item: item)
                }
        }
    }
}

/// The Ports button's glyph, with a dot while anything is forwarded, so a forward left open is
/// visible with the popover shut. A dot on the same glyph rather than a filled variant of it: the
/// filled arrows read as a different control, and a dot is how a toolbar already says "live".
struct CloudPortsIcon: View {
    var isForwarding: Bool

    var body: some View {
        Image(systemName: "arrow.left.arrow.right")
            .overlay(alignment: .topTrailing) {
                if isForwarding {
                    Circle()
                        .fill(Palette.positive)
                        .frame(width: 6, height: 6)
                        .offset(x: 4, y: -3)
                        .accessibilityHidden(true)
                }
            }
    }
}

/// Who else has the workspace open: initials, with names in the tooltip.
struct CloudPresenceView: View {
    var people: [PresenceRecord]

    var body: some View {
        HStack(spacing: -6) {
            ForEach(people.prefix(4), id: \.userID) { person in
                Text(Self.initials(person.name))
                    .font(.caption2.weight(.semibold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Palette.accent.opacity(0.2)))
                    .overlay(Circle().strokeBorder(Palette.windowBackground, lineWidth: 1.5))
            }
        }
        .help(people.map(\.name).joined(separator: ", ") + (people.count == 1 ? " has this open" : " have this open"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(people.map(\.name).joined(separator: ", ") + " also here")
    }

    static func initials(_ name: String) -> String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}
