import BloomCore
import SwiftUI

/// The panel that opens over the composer while somebody is typing an `@handle` at the head of a
/// message in a shared Cloud workspace.
///
/// **The same panel as the file menu, over a different list, and that is the whole design.** `@`
/// means a file everywhere in Bloom and has since the composer existed; at the start of a message
/// in a workspace with somebody else in it, it means a person or the agent. The rule for which is
/// which is `MentionAddress.offersPeople`, in the core, and a menu that appeared with nothing in it
/// would be this feature promising something it has none of: where there is nobody to address, the
/// `@` keeps its file meaning and this never opens.
///
/// **The agent heads the list**, because it is where most messages go and because it was the one
/// row you could not pick: `@bloom` addressed it perfectly well and the menu said "Nobody here is
/// called blo" while you typed it. See `MentionCandidate`.
///
/// It renders and nothing else. Selection and the arrow keys belong to `ComposerPrompt`, because
/// the text view keeps first responder the whole time and is the only thing that sees the keys.
struct PersonMentionMenu: View {
    var candidates: [MentionCandidate]
    var query: String
    var selectedIndex: Int
    var maxHeight: CGFloat = MenuLayout.maxHeight
    var onPick: @MainActor (MentionCandidate) -> Void
    var onHighlight: @MainActor (Int) -> Void = { _ in }

    var body: some View {
        MenuPanel {
            if candidates.isEmpty {
                // An empty query always matches the agent, so the only way to reach this row is a
                // query that names nobody. The "nobody has access to this workspace" wording this
                // used to carry became unreachable when the agent joined the list.
                MenuEmptyRow(text: "Nobody here is called \(query)")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                                PersonMentionRow(
                                    candidate: candidate,
                                    isSelected: index == selectedIndex,
                                    onPick: { onPick(candidate) },
                                    onHover: { onHighlight(index) }
                                )
                                // Identity is the person, never the slot: a lazy stack serves the
                                // views it cached for a position while the list changes under an
                                // open menu, which picks whoever is drawn rather than whoever is
                                // highlighted. Written down in `SlashCommandMenu` and true here.
                                .id(candidate.id)
                            }
                        }
                        .padding(Metrics.spacingSmall)
                    }
                    .frame(maxHeight: maxHeight)
                    .onChange(of: selectedIndex) { _, index in
                        guard candidates.indices.contains(index) else { return }
                        proxy.scrollTo(candidates[index].id)
                    }
                }
            }
        }
    }
}

/// One person in the mention menu: what they are called, then the handle somebody types.
///
/// **The name first, because that is what a person is looking for, and the handle beside it because
/// that is what they are about to type.** No avatar and no address: the list is offered to whoever
/// is typing, and somebody holding a share link is typing on the same machine, so the handle and
/// the name are the whole of what a menu may show. See `WorkspaceMember`.
struct PersonMentionRow: View {
    var candidate: MentionCandidate
    var isSelected: Bool
    var onPick: @MainActor () -> Void
    var onHover: @MainActor () -> Void

    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: Metrics.spacing) {
                Text(candidate.name)
                    .font(Typo.body)
                    .foregroundStyle(isEmphasized ? Palette.selectedEmphasizedText : Palette.textPrimary)
                    .lineLimit(1)

                Text("@" + candidate.handle)
                    .font(Typo.label)
                    .foregroundStyle(
                        isEmphasized
                            ? Palette.selectedEmphasizedText.opacity(0.75)
                            : Palette.textTertiary
                    )
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.spacingWide)
            .padding(.vertical, Metrics.spacingSmall)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isSelected ? (isEmphasized ? Palette.selectedEmphasized : Palette.selected) : .clear,
            in: RoundedRectangle(cornerRadius: Metrics.cornerSmall)
        )
        .onHover { if $0 { onHover() } }
    }

    private var isEmphasized: Bool { isSelected && activeState == .key }
}
