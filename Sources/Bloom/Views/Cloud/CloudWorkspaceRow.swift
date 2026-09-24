import BloomClient
import BloomCore
import SwiftUI

/// One Cloud workspace in the sidebar, drawn from runbloom.app's list alone, so a row never wakes
/// the machine it describes.
///
/// **Built from the local row's own pieces**, so the two sections of the column read as one list:
/// the same name text with the same unread weight, the same mark drawn by the same policy (a mark
/// only when something is happening or something is wanted), the same quiet diff figures, and the
/// same label style that keeps the mark in the icon column. What is here that a local row has not
/// got is the lock and the sharing mark, which are facts only a shared workspace has.
struct CloudWorkspaceRow: View {
    var item: CloudWorkspaceItem
    var isSelected: Bool
    var showsDiffStats = false
    /// Raises the Cloud archive popover, which asks the machine what is about to be lost and says
    /// the conversation goes with it. See `CloudArchivePopover`.
    var onArchive: () -> Void = {}

    @Environment(AppModel.self) private var app
    @Environment(\.backgroundProminence) private var backgroundProminence
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    /// What the machine says it is doing, while its stream is open to say. Nil sends both readings
    /// below back to runbloom.app's poll, which is all there is for a workspace nobody has open.
    ///
    /// **This is the fix for a spinner that outlived its turn.** The poll had said `running`, the
    /// turn ended on the machine, and nothing told the poll: the row span beside a conversation
    /// that had already answered him. Two witnesses, and the one that carried the event that ended
    /// the turn is the one to believe. See `CloudWorkspaceSession.sidebarActivity`.
    private var activity: CloudWorkspaceStatus.Activity? {
        app.cloud.existingSession(for: CloudWorkspaceID(item.id))?.sidebarActivity
    }

    /// What the machine is doing, in the sentence VoiceOver reads for the row.
    private var status: CloudWorkspaceStatus { CloudWorkspaceStatus(item: item, activity: activity) }
    /// The same fact in the sidebar's own vocabulary, for the mark. See `CloudSidebarMark`.
    private var mark: WorkspaceStatus { WorkspaceStatus(cloudItem: item, activity: activity) }

    private var isEmphasized: Bool { backgroundProminence == .increased }

    var body: some View {
        Label {
            HStack(spacing: Metrics.spacing) {
                WorkspaceNameText(name: item.displayName, isUnread: item.unread)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if status == .asleep, item.summary != nil {
                    Image(systemName: "moon.zzz")
                        .font(Typo.micro)
                        .foregroundStyle(isEmphasized ? Palette.textInverted : Palette.textTertiary)
                        .accessibilityHidden(true)
                }
                WorkspaceColourDot(hex: item.colour, accessibilityName: colourName)
                sharingMark
                Spacer(minLength: Metrics.spacingSmall)
                if showsDiffStats, let diff = item.summary?.diff, diff.files > 0 {
                    DiffStatLabel(additions: diff.additions, deletions: diff.deletions, compact: true, quiet: true)
                        .opacity(isHovered && item.canArchive ? 0 : 1)
                }
                if let project = item.project {
                    CloudProjectIcon(
                        teamID: CloudTeamID(item.teamID),
                        projectID: CloudProjectID(project.id),
                        repository: project.repository,
                        iconURL: project.iconURL,
                        size: Metrics.repoIconSmall,
                        accessibilityName: "Project \(project.repository)"
                    )
                    .frame(width: SidebarMetrics.rowButton)
                    .opacity(isHovered && item.canArchive ? 0 : 1)
                }
            }
            // The local row's own hover control and the ground it clears, so the archive box is
            // under the pointer in the same place in both sections of the column.
            .modifier(SidebarRowTrailingControl(isShown: (isHovered || isArchiveActive) && item.canArchive) { archiveButton })
            .animation(reduceMotion ? nil : Motion.hover, value: isHovered)
        } icon: {
            // Every state, as the local row draws it, so the two sections of the column agree.
            WorkspaceStatusGlyph(status: mark, isOnSelection: isEmphasized)
        }
        .labelStyle(SidebarRowLabelStyle())
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .task(id: projectSettingsKey) { await app.cloud.loadProjectIconSettings(for: item) }
        .accessibilityElement(children: .combine)
        .accessibilityValue(status.phrase + (item.unread ? ", unread" : ""))
        .environment(\.isOnEmphasizedSelection, isEmphasized)
    }

    private var projectSettingsKey: String? {
        item.project.map { "\(item.teamID):\($0.id):\($0.settingsURL ?? "")" }
    }

    /// The same box a local row draws, raising the Cloud archive rather than the local one.
    private var archiveButton: some View {
        Button(action: onArchive) {
            Image(systemName: "trash")
                .font(Typo.caption)
                .frame(width: SidebarMetrics.rowButton, height: SidebarMetrics.rowButton)
                .contentShape(RoundedRectangle(cornerRadius: Metrics.cornerSmall))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEmphasized ? Palette.textInverted : Palette.textSecondary)
        .help("Delete Workspace")
        .accessibilityLabel("Delete workspace \(item.displayName)")
        // Anchored here, as a local row anchors its own. Held open, and the box with it, while
        // `cloud.archiving` names this workspace, whichever control asked. See `CloudArchivePopover`.
        .popover(isPresented: archiveBinding, arrowEdge: .leading) {
            CloudArchivePopover(id: CloudWorkspaceID(item.id)) { app.cloud.archiving = nil }
        }
    }

    private var isArchiveActive: Bool {
        app.cloud.isAskingToArchive(CloudWorkspaceID(item.id), at: .row)
    }

    private var colourName: String? {
        guard let colour = item.colour, HexColor(hex: colour) != nil else { return nil }
        return WorkspaceColour.named(colour)?.name ?? "#\(colour)"
    }

    private var archiveBinding: Binding<Bool> {
        Binding(
            get: { isArchiveActive },
            set: { if !$0, isArchiveActive { app.cloud.archiving = nil } }
        )
    }

    /// Whether other people can see it, which is the one thing about a Cloud workspace's row a
    /// local one has no word for.
    ///
    /// There was a lock as well, for a private workspace a team owner or admin could see and not
    /// open. runbloom.app no longer lists those at all (fb24dd3, "private means private"): every
    /// workspace this Mac is given is one it can open, so the mark had nothing left to say.
    @ViewBuilder
    private var sharingMark: some View {
        let ink = isEmphasized ? Palette.textInverted : Palette.textTertiary
        if item.sharedWithTeam || item.role == "collaborator" {
            Image(systemName: "person.2")
                .font(Typo.micro)
                .foregroundStyle(ink)
                .accessibilityLabel(item.role == "collaborator" ? "Shared with you" : "Shared with your team")
        }
    }
}
