import AppKit
import BloomClient
import BloomCore
import SwiftUI

/// Sharing a Cloud workspace: with the whole team, with named collaborators, and as a public link
/// to its preview.
struct CloudSharePopover: View {
    var workspaceID: CloudWorkspaceID
    var item: CloudWorkspaceItem?
    @Environment(AppModel.self) private var app
    @State private var sharing: CloudSharing?
    @State private var removing: CloudWorkspaceMembers.Member?
    @State private var copiedShareID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            if let sharing {
                content(sharing)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .frame(width: 360)
        .task {
            guard sharing == nil, let item else { return }
            let model = CloudSharing(workspaceID: workspaceID, teamID: item.teamID, cloud: app.cloud)
            sharing = model
            await model.load()
        }
    }

    @ViewBuilder
    private func content(_ sharing: CloudSharing) -> some View {
        Text("Share this Cloud workspace")
            .font(.headline)

        Toggle(isOn: Binding(
            get: { sharing.members?.sharedWithTeam ?? item?.sharedWithTeam ?? false },
            set: { shared in Task { await sharing.setSharedWithTeam(shared) } }
        )) {
            VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                Text("Everyone in \(app.cloud.team(item?.teamID ?? "")?.name ?? "the team")")
                Text("Once shared, every turn runs on the team's agent key, including yours.")
                    .font(.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(sharing.isBusy || sharing.members == nil)

        if let members = sharing.members {
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                Text("People").font(.subheadline.weight(.medium))
                ForEach(members.members) { member in
                    HStack {
                        Text(member.user.name)
                        Text(member.role == "owner" ? "Owner" : "Collaborator")
                            .foregroundStyle(Palette.textSecondary)
                        Spacer()
                        if member.role != "owner" {
                            Button("Remove") { removing = member }
                                .buttonStyle(.borderless)
                                .disabled(sharing.isBusy)
                        }
                    }
                }
                if !sharing.addable.isEmpty {
                    Menu("Add a Collaborator") {
                        ForEach(sharing.addable) { person in
                            Button(person.name) { Task { await sharing.add(person) } }
                        }
                    }
                    .fixedSize()
                    .disabled(sharing.isBusy)
                }
            }
        }

        Divider()

        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            HStack {
                Text("Preview links").font(.subheadline.weight(.medium))
                Spacer()
                Button("Create Link") {
                    Task {
                        if let share = await sharing.createShare() { copy(share) }
                    }
                }
                .buttonStyle(.borderless)
                .disabled(sharing.isBusy)
            }
            Text("Anyone with a link can open the project's app for an hour at a time, until the link expires or you revoke it.")
                .font(.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(sharing.shares) { share in
                HStack {
                    Text(share.url.absoluteString)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(copiedShareID == share.id ? "Copied" : "Copy") { copy(share) }
                        .buttonStyle(.borderless)
                    Button("Revoke") { Task { await sharing.revoke(share) } }
                        .buttonStyle(.borderless)
                        .disabled(sharing.isBusy)
                }
            }
        }

        if let problem = sharing.problem {
            Text(problem)
                .foregroundStyle(Palette.negative)
                .fixedSize(horizontal: false, vertical: true)
        }

        EmptyView()
            .confirmationDialog(
                "Remove \(removing?.user.name ?? "this person")?",
                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
            ) {
                Button("Remove", role: .destructive) {
                    if let member = removing { Task { await sharing.remove(member) } }
                    removing = nil
                }
            } message: {
                Text("Their queued messages are cancelled, a turn they started is ended, and they are disconnected from this Cloud workspace straight away.")
            }
    }

    private func copy(_ share: PreviewShare) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(share.url.absoluteString, forType: .string)
        copiedShareID = share.id
    }
}
