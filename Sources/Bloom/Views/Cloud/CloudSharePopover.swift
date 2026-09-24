import AppKit
import BloomClient
import BloomCore
import SwiftUI

/// Sharing a Cloud workspace: with the whole team, with named collaborators, and as a public link
/// to its preview.
///
/// **Two cards, because these are two decisions with two audiences.** It was one undifferentiated
/// column: a bare checkbox with two lines of grey under it, then a list of people dominated by a
/// grey popup button that was the heaviest thing in the popover, then a "Create Link" text button
/// floating beside a heading above three lines of caveats nobody reads at the moment they are
/// deciding. The owner asked for it to be nicer, chose between two drawn alternatives, and picked
/// this one for the reason it was drawn: **a link is the only thing here that hands something to
/// somebody outside the team**, and in one column that was the quietest control on screen.
///
/// So "Who can work in it" holds the team switch and the people, and turning the switch on visibly
/// changes what that card is about; "Who can see the app" holds the link and its own caveat. The
/// sentence about the agent key is word for word what it was, because its meaning is exact and was
/// argued over. The link's caveat keeps every clause it had, in two sentences rather than one.
///
/// **Only the owner may change any of it, and the popover says so rather than being refused.**
/// Everybody else gets the same two cards with the controls dimmed and one line above them, which
/// is `CloudShareControls`. The link row shows its actual expiry before somebody sends it.
/// "An hour at a time" describes a viewer's session, while the link itself can last a week.
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
        .frame(width: 380)
        .task {
            guard sharing == nil, let item else { return }
            let model = CloudSharing(workspaceID: workspaceID, teamID: item.teamID, cloud: app.cloud)
            sharing = model
            await model.load()
        }
    }

    @ViewBuilder
    private func content(_ sharing: CloudSharing) -> some View {
        // **Two elements rather than one sentence, because the name is not a word.** It read
        // "Share Open up a browser pane next to this chat", which is what gluing a fixed word to
        // somebody's data produces: the owner names his workspaces in sentences, so a title built
        // by concatenation is a title built out of whatever he typed. The same fault as the
        // archive sheet's double question mark, and the same answer: the name is its own thing,
        // drawn as itself, and the word above it says what this is.
        VStack(alignment: .leading, spacing: 1) {
            Text("Share")
                .font(Typo.heading)
            Text(item?.displayName ?? "this Bloom Cloud workspace")
                .font(Typo.body)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        // Said once, above the controls it explains. See `CloudShareControls`.
        if !canChange {
            Text(CloudShareControls.othersCannotChange)
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        people(sharing)
        preview(sharing)

        if let problem = sharing.problem {
            Text(problem)
                .font(Typo.caption)
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
                Text("Their queued messages are cancelled, a turn they started is ended, and they are disconnected from this Bloom Cloud workspace straight away.")
            }
    }

    /// Whether this account may change any of it, which is what dims every control below rather
    /// than letting runbloom.app refuse one after it was pressed.
    private var canChange: Bool { CloudShareControls.canChange(role: item?.role) }

    // MARK: - Who can work in it

    /// The team by name where the account knows it, and "the team" where it does not: a switch
    /// that says who it shares with is the whole of what makes the consequence under it legible.
    private var teamLabel: String {
        guard let name = app.cloud.team(item?.teamID ?? "")?.name else { return "Everyone in the team" }
        return "Everyone in \(name)"
    }

    private func people(_ sharing: CloudSharing) -> some View {
        card {
            Text("Who can work in it").fontWeight(.medium)

            // **The switch has the row to itself, because its label carries a name.** It shared
            // one with the heading and took whatever was left after it, which was not enough for
            // "Everyone in Spatie": a six letter team truncated, so almost every team would have.
            // A label that holds somebody's data cannot be given the remainder of a line, and the
            // answer is not a shorter sentence fitted to an imaginary average team.
            Toggle(isOn: Binding(
                get: { sharing.members?.sharedWithTeam ?? item?.sharedWithTeam ?? false },
                set: { shared in Task { await sharing.setSharedWithTeam(shared) } }
            )) {
                Text(teamLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!canChange || sharing.isBusy || sharing.members == nil)

            // Word for word what it was. See the head of this file.
            Text("Once shared, every turn runs on the team's agent key, including yours.")
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let members = sharing.members {
                Divider()
                ForEach(members.members) { member in
                    person(member, in: sharing)
                }
                if canChange, !sharing.addable.isEmpty {
                    Menu {
                        ForEach(sharing.addable) { candidate in
                            Button(candidate.name) { Task { await sharing.add(candidate) } }
                        }
                    } label: {
                        Label("Add someone", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(!canChange || sharing.isBusy)
                }
            }
        }
    }

    /// One person: their initials, their name, what they are, and the way to take them out.
    ///
    /// **"Cannot push" is a real state and stays**, which the mock was checked against rather than
    /// copied from: `hasPushAccess` is false for somebody who has no push access to the repository
    /// or has not connected GitHub, and such a person cannot prompt in a shared Cloud workspace at
    /// all. It is the one thing in this list that explains why sharing with somebody did not give
    /// them what you expected, so it is drawn in the warning ink with the whole of it in the help.
    private func person(_ member: CloudWorkspaceMembers.Member, in sharing: CloudSharing) -> some View {
        HStack(spacing: Metrics.spacingWide) {
            Avatar(name: member.user.name)
            VStack(alignment: .leading, spacing: 0) {
                // Wrapped rather than cut: a person's name is data on a row with two controls, and
                // the same reasoning as the switch above applies to it one size down.
                Text(member.user.name)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(member.role == "owner" ? "Owner" : sharing.hasLeftTeam(member) ? "Left the team" : "Collaborator")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
            Spacer(minLength: Metrics.spacingSmall)
            if member.hasPushAccess == false {
                Text("Cannot push")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.warning)
                    .help("They have no push access to the repository, or have not connected GitHub, so they cannot prompt in a shared Bloom Cloud workspace.")
            }
            if canChange, member.role != "owner" {
                Button("Remove", systemImage: "xmark") { removing = member }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(Palette.textTertiary)
                    .disabled(!canChange || sharing.isBusy)
                    .help("Remove \(member.user.name) from this Bloom Cloud workspace")
            }
        }
    }

    // MARK: - Who can see the app

    private func preview(_ sharing: CloudSharing) -> some View {
        card {
            HStack(alignment: .firstTextBaseline) {
                Text("Who can see the app").fontWeight(.medium)
                Spacer(minLength: Metrics.spacing)
                Button("Create link") {
                    Task {
                        if let share = await sharing.createShare() { copy(share) }
                    }
                }
                .controlSize(.small)
                .disabled(!canChange || sharing.isBusy)
            }

            Text("Anyone with the link can open the project's app, an hour at a time. It stops working when you revoke it, when it expires, or when you can no longer share this Bloom Cloud workspace.")
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(sharing.shares) { share in
                VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                    HStack(spacing: Metrics.spacingSmall) {
                        Image(systemName: "link")
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textTertiary)
                            .accessibilityHidden(true)
                        Text(share.url.absoluteString)
                            .font(Typo.caption)
                            .monospaced()
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: Metrics.spacingSmall)
                        Button {
                            copy(share)
                        } label: {
                            Label(copiedShareID == share.id ? "Copied link" : "Copy link",
                                  systemImage: copiedShareID == share.id ? "checkmark" : "doc.on.doc")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help(copiedShareID == share.id ? "Copied link" : "Copy link")
                    }
                    .padding(Metrics.spacingSmall)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall))

                    HStack {
                        if let expiry = CloudShareControls.expiry(of: share) {
                            Text(expiry)
                                .font(Typo.caption)
                                .foregroundStyle(Palette.textTertiary)
                        }
                        Spacer()
                        if canChange {
                            Menu {
                                Button("Revoke link", role: .destructive) {
                                    Task { await sharing.revoke(share) }
                                }
                            } label: {
                                Label("Link actions", systemImage: "ellipsis")
                            }
                            .labelStyle(.iconOnly)
                            .menuStyle(.borderlessButton)
                            .controlSize(.small)
                            .fixedSize()
                            .disabled(sharing.isBusy)
                            .help("Link actions")
                        }
                    }
                }
            }
        }
    }

    // MARK: - The card itself

    /// What makes the two decisions two things rather than one column with a rule in it. Sunken
    /// rather than outlined, which is how every other grouped thing in this window is drawn.
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingWide, content: content)
            .padding(Metrics.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.corner))
    }

    private func copy(_ share: PreviewShare) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(share.url.absoluteString, forType: .string)
        copiedShareID = share.id
    }
}

/// A person's initials in a circle, which is what makes the list read as people rather than as
/// rows of text. No picture: runbloom.app does not send one, and a placeholder that looks like an
/// avatar is a picture of nobody.
private struct Avatar: View {
    var name: String

    var body: some View {
        Circle()
            .fill(Palette.surface)
            .overlay(Circle().strokeBorder(Palette.border))
            .overlay(
                Text(initials)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
            )
            .frame(width: 26, height: 26)
            .accessibilityHidden(true)
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init)
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }
}
