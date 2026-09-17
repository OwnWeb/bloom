import BloomClient
import BloomCore
import BloomProtocol
import SwiftUI

/// The top of a Cloud workspace's column: what it is, who else has it open, its panes, and what
/// can be done with it.
struct CloudWorkspaceHeader: View {
    var session: CloudWorkspaceSession
    var item: CloudWorkspaceItem?
    @Environment(AppModel.self) private var app
    @State private var isSharing = false

    private var name: String {
        session.state.workspace?.name ?? item?.displayName ?? "Cloud workspace"
    }

    private var branch: String {
        session.state.workspace?.branch ?? item?.displayBranch ?? ""
    }

    /// Everybody with the workspace open but the reader.
    private var others: [PresenceRecord] {
        session.state.presence.filter { $0.userID != session.readerID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Metrics.gutter) {
                Image(systemName: "cloud")
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                    Text(name)
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: Metrics.spacing) {
                        if let repository = item?.project?.repository {
                            Text(repository)
                        }
                        Text(branch)
                            .font(.callout.monospaced())
                        if let pullRequest = session.state.workspace?.pullRequest, let url = URL(string: pullRequest.url) {
                            Link("#\(pullRequest.number)", destination: url)
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                }
                Spacer(minLength: Metrics.gutter)
                if !others.isEmpty {
                    CloudPresenceView(people: others)
                }
                Button {
                    Task { await session.openPreview() }
                } label: {
                    Label("Preview", systemImage: "safari")
                }
                .help("Open the project's app in your browser")
                .disabled(!session.allows("preview"))
                Button {
                    isSharing = true
                } label: {
                    Label("Share", systemImage: "person.2")
                }
                .help("Share this Cloud workspace")
                .disabled(item?.role != "owner")
                .popover(isPresented: $isSharing, arrowEdge: .bottom) {
                    CloudSharePopover(workspaceID: session.id, item: item)
                }
                Button {
                    app.cloud.archiving = session.id
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .help("Archive this Cloud workspace")
                .disabled(item?.canArchive != true)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, Metrics.inset)

            CloudPaneStrip(session: session)
            Divider()
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

/// The chats of a Cloud workspace and its other panes, as one strip.
struct CloudPaneStrip: View {
    var session: CloudWorkspaceSession

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Metrics.spacingSmall) {
                ForEach(session.state.topLevelChats, id: \.id) { chat in
                    let id = SessionID(chat.id)
                    tab(title: chat.title, systemImage: chat.agent == "codex" ? "chevron.left.forwardslash.chevron.right" : "bubble.left",
                        isSelected: session.pane == .chat && session.selectedChatID == id,
                        isBusy: session.state.chats[chat.id]?.isRunning == true) {
                        session.selectedChatID = id
                        session.pane = .chat
                    }
                    .contextMenu {
                        Button("Close Chat") { Task { await session.closeChat(id) } }
                            .disabled(!session.allows("prompt"))
                    }
                }
                Button {
                    session.pane = .chat
                    Task { await session.newChat() }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New Chat")
                .disabled(session.isOpeningChat || session.phase != .live || !session.allows("prompt"))
                Divider().frame(height: 14)
                tab(title: "Terminal", systemImage: "terminal", isSelected: session.pane == .terminal, isBusy: false) { session.pane = .terminal }
                tab(title: "Changes", systemImage: "plusminus", isSelected: session.pane == .changes, isBusy: false) { session.pane = .changes }
                tab(title: "Setup", systemImage: "hammer", isSelected: session.pane == .setup,
                    isBusy: session.state.setup?.state == "running") { session.pane = .setup }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, Metrics.spacingWide)
        }
    }

    private func tab(title: String, systemImage: String, isSelected: Bool, isBusy: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Metrics.spacingSmall) {
                Image(systemName: systemImage)
                Text(title).lineLimit(1)
                if isBusy {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.horizontal, Metrics.spacingWide)
            .padding(.vertical, Metrics.spacingSmall)
            .background(RoundedRectangle(cornerRadius: Metrics.corner).fill(isSelected ? Palette.accent.opacity(0.15) : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
