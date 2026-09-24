import AppKit
import BloomCore
import SwiftUI

#if DEBUG
/// Two answers to "make this dialog nicer", drawn rather than described.
///
/// **Rendered offscreen with `ImageRenderer`**, so nothing opens a window, takes focus or appears
/// over what the owner is reading. The gallery capture beside this one uses the window server and
/// therefore puts a window on screen, which is an interruption to a person rather than a step in a
/// task; a popover mock needs no window to be looked at.
///
/// What both options keep, because the meaning was argued over and is exact: **"Once shared, every
/// turn runs on the team's agent key, including yours."** The link's caveat keeps every clause it
/// had, split into two sentences so the clauses can be read.
@MainActor
enum SharePopoverGallery {

    // MARK: - Drawn stand-ins
    //
    // **`ImageRenderer` cannot draw an AppKit-backed control**: a `Toggle` or a `Button` comes out
    // as a yellow placeholder, which is what the first pass of this gallery produced. A mock is a
    // picture of an arrangement rather than a working popover, so the controls are drawn here and
    // the real thing uses the real ones.

    static func switchMark(on: Bool) -> some View {
        Capsule()
            .fill(on ? Palette.controlAccent : Palette.border)
            .frame(width: 34, height: 20)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(.white).frame(width: 16, height: 16).padding(2)
                    .shadow(radius: 0.5, y: 0.5)
            }
    }

    static func buttonMark(_ title: String, prominent: Bool = false) -> some View {
        Text(title)
            .font(Typo.caption)
            .foregroundStyle(prominent ? Color.white : Palette.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(prominent ? Palette.controlAccent : Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(prominent ? .clear : Palette.border)
            )
    }

    static func linkMark(_ title: String) -> some View {
        Text(title).font(Typo.caption).foregroundStyle(Palette.link)
    }

    static func glyphMark(_ name: String) -> some View {
        Image(systemName: name).font(.caption).foregroundStyle(Palette.textTertiary)
    }

    static func render(into directory: String) -> [String] {
        var written: [String] = []
        for (name, view) in [("share-a", AnyView(OptionA())), ("share-b", AnyView(OptionB()))] {
            for appearance in ["light", "dark"] {
                let renderer = ImageRenderer(content:
                    view
                        .environment(\.colorScheme, appearance == "dark" ? .dark : .light)
                        .background(Palette.surface)
                )
                renderer.scale = 2
                guard let image = renderer.nsImage,
                      let data = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: data),
                      let png = rep.representation(using: .png, properties: [:]) else { continue }
                let path = "\(directory)/\(name)-\(appearance).png"
                try? png.write(to: URL(filePath: path))
                written.append(path)
            }
        }
        return written
    }

    /// The people who can open it, the team included, and one deliberate primary action.
    ///
    /// The argument: sharing with the team and adding a person are the same decision asked twice,
    /// so they are one list. The team is its first row, with the switch on it, and the consequence
    /// is a line under that row rather than a caption under a checkbox. Adding somebody is a `+` on
    /// the section rather than a grey popup button that outweighs the list it belongs to. The link
    /// is the second decision and sits under a rule, with the button that makes one as the only
    /// filled control in the popover, because it is the only thing here that hands something to
    /// somebody outside the team.
    struct OptionA: View {
        var body: some View {
            VStack(alignment: .leading, spacing: Metrics.gutter) {
                Text("Share Queue retries")
                    .font(Typo.heading)

                HStack {
                    Text("Who can open it").font(Typo.caption).foregroundStyle(Palette.textSecondary)
                    Spacer()
                    HStack(spacing: Metrics.spacingSmall) {
                        glyphMark("plus")
                        linkMark("Add someone")
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    row {
                        Circle().fill(Palette.accent.opacity(0.18))
                            .overlay(Image(systemName: "person.2").font(.caption).foregroundStyle(Palette.accent))
                            .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Everyone in Spatie").fontWeight(.medium)
                            Text("Once shared, every turn runs on the team's agent key, including yours.")
                                .font(Typo.caption)
                                .foregroundStyle(Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: Metrics.spacing)
                        switchMark(on: true)
                    }
                    Divider().padding(.leading, 40)
                    person(initials: "FV", name: "Freek Van der Herten", role: "Owner", removable: false)
                    Divider().padding(.leading, 40)
                    person(initials: "SB", name: "Seb De Deyne", role: "Collaborator", removable: true)
                }
                .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.corner))

                VStack(alignment: .leading, spacing: Metrics.spacingWide) {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Preview link").fontWeight(.medium)
                            Text("Anyone with the link can open the project's app, an hour at a time.")
                                .font(Typo.caption)
                                .foregroundStyle(Palette.textSecondary)
                        }
                        Spacer(minLength: Metrics.spacing)
                        buttonMark("Create", prominent: true)
                    }
                    HStack(spacing: Metrics.spacingSmall) {
                        Image(systemName: "link").font(.caption).foregroundStyle(Palette.textTertiary)
                        Text("runbloom.app/p/8c1f…").font(Typo.caption).monospaced()
                        Spacer()
                        linkMark("Copy")
                        linkMark("Revoke")
                    }
                    .padding(Metrics.spacingWide)
                    .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.corner))
                    Text("It stops working when you revoke it, when it expires, or when you can no longer share this Cloud workspace.")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(width: 380)
        }

        private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
            HStack(spacing: Metrics.spacingWide, content: content)
                .padding(.horizontal, Metrics.spacingWide)
                .padding(.vertical, Metrics.spacingWide)
        }

        private func person(initials: String, name: String, role: String, removable: Bool) -> some View {
            row {
                Circle().fill(Palette.surface)
                    .overlay(Text(initials).font(.caption2).foregroundStyle(Palette.textSecondary))
                    .overlay(Circle().strokeBorder(Palette.border))
                    .frame(width: 28, height: 28)
                Text(name)
                Spacer(minLength: Metrics.spacing)
                Text(role).font(Typo.caption).foregroundStyle(Palette.textTertiary)
                if removable { glyphMark("xmark") }
            }
        }
    }

    /// Two questions, each with its own card, and the consequence where the decision is.
    ///
    /// The argument: who can work in it and who can look at the app are different risks with
    /// different audiences, so they are two cards rather than one column. Inside the first, the
    /// team switch is the heading of the card and the people are its contents, so turning it on
    /// visibly changes what the card is about. The link card is quiet until there is a link, and
    /// its caveat sits on the link rather than above the button that makes one.
    struct OptionB: View {
        var body: some View {
            VStack(alignment: .leading, spacing: Metrics.gutter) {
                Text("Share Queue retries")
                    .font(Typo.heading)

                card {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Who can work in it").fontWeight(.medium)
                        Spacer()
                        HStack(spacing: Metrics.spacingSmall) {
                            Text("Everyone in Spatie").font(Typo.caption)
                            switchMark(on: false)
                        }
                    }
                    Text("Once shared, every turn runs on the team's agent key, including yours.")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider().padding(.vertical, 2)
                    HStack(spacing: Metrics.spacingWide) {
                        Text("FV").font(.caption2).frame(width: 24, height: 24)
                            .background(Circle().fill(Palette.surfaceSunken))
                        Text("Freek Van der Herten")
                        Spacer()
                        Text("Owner").font(Typo.caption).foregroundStyle(Palette.textTertiary)
                    }
                    HStack(spacing: Metrics.spacingWide) {
                        Text("SB").font(.caption2).frame(width: 24, height: 24)
                            .background(Circle().fill(Palette.surfaceSunken))
                        Text("Seb De Deyne")
                        Spacer()
                        Text("Cannot push").font(Typo.caption).foregroundStyle(Palette.warning)
                        glyphMark("xmark")
                    }
                    HStack(spacing: Metrics.spacingSmall) {
                        glyphMark("plus")
                        linkMark("Add someone")
                    }
                    .padding(.top, 2)
                }

                card {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Who can see the app").fontWeight(.medium)
                        Spacer()
                        buttonMark("Create link")
                    }
                    Text("Anyone with the link can open the project's app, an hour at a time. It stops working when you revoke it, when it expires, or when you can no longer share this Cloud workspace.")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                        HStack(spacing: Metrics.spacingSmall) {
                            glyphMark("link")
                            Text("https://runbloom.app/share/8c1f…")
                                .font(Typo.caption)
                                .monospaced()
                                .foregroundStyle(Palette.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: Metrics.spacingSmall)
                            glyphMark("doc.on.doc")
                        }
                        .padding(Metrics.spacingSmall)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall))
                        HStack {
                            Text("Expires in 168 hours")
                                .font(Typo.caption)
                                .foregroundStyle(Palette.textTertiary)
                            Spacer()
                            glyphMark("ellipsis")
                        }
                    }
                }
            }
            .padding(16)
            .frame(width: 380)
        }

        private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
            VStack(alignment: .leading, spacing: Metrics.spacingWide, content: content)
                .padding(Metrics.gutter)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Metrics.corner))
        }
    }
}
#endif
