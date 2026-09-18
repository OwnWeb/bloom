import BloomCore
import SwiftUI

/// The panel that opens over the composer while somebody is typing an `@handle` at the head of a
/// message in a shared Cloud workspace.
///
/// **The same panel as the file menu, over a different list, and that is the whole design.** `@`
/// means a file everywhere in Bloom and has since the composer existed; at the start of a message
/// in a workspace with somebody else in it, it means a person. The rule for which is which is
/// `MentionAddress.offersPeople`, in the core, and a menu that appeared with nothing in it would be
/// this feature promising something it has none of: where there is nobody to address, the `@` keeps
/// its file meaning and this never opens.
///
/// It renders and nothing else. Selection and the arrow keys belong to `ComposerPrompt`, because
/// the text view keeps first responder the whole time and is the only thing that sees the keys.
struct PersonMentionMenu: View {
    var people: [ComposerAudience.Person]
    var query: String
    var selectedIndex: Int
    var maxHeight: CGFloat = MenuLayout.maxHeight
    var onPick: @MainActor (ComposerAudience.Person) -> Void
    var onHighlight: @MainActor (Int) -> Void = { _ in }

    var body: some View {
        MenuPanel {
            if people.isEmpty {
                MenuEmptyRow(
                    text: query.isEmpty
                        ? "Nobody else has access to this Cloud workspace"
                        : "Nobody here is called \(query)"
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(people.enumerated()), id: \.element.id) { index, person in
                                PersonMentionRow(
                                    person: person,
                                    isSelected: index == selectedIndex,
                                    onPick: { onPick(person) },
                                    onHover: { onHighlight(index) }
                                )
                                // Identity is the person, never the slot: a lazy stack serves the
                                // views it cached for a position while the list changes under an
                                // open menu, which picks whoever is drawn rather than whoever is
                                // highlighted. Written down in `SlashCommandMenu` and true here.
                                .id(person.id)
                            }
                        }
                        .padding(Metrics.spacingSmall)
                    }
                    .frame(maxHeight: maxHeight)
                    .onChange(of: selectedIndex) { _, index in
                        guard people.indices.contains(index) else { return }
                        proxy.scrollTo(people[index].id)
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
    var person: ComposerAudience.Person
    var isSelected: Bool
    var onPick: @MainActor () -> Void
    var onHover: @MainActor () -> Void

    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: Metrics.spacing) {
                Text(person.name)
                    .font(Typo.body)
                    .foregroundStyle(isEmphasized ? Palette.selectedEmphasizedText : Palette.textPrimary)
                    .lineLimit(1)

                Text("@" + person.handle)
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
