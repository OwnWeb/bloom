import SwiftUI
import BloomCore

/// The menu an `@` opens at the head of a message in a shared Cloud workspace, in the four states
/// a person types their way through.
///
/// It exists because **the agent's own row is the one that was missing and the one nobody could
/// see was missing**: `@bloom` addressed the agent perfectly well when the message was sent, and
/// the menu said "Nobody here is called blo" while it was being typed, which reads as the feature
/// being broken rather than as the agent living somewhere else. A picture of the four states is
/// the cheapest way to keep that row at the head of the list and to keep it looking like a row
/// rather than like a heading.
///
/// **It is a window capture and not an offscreen one, and that was measured rather than assumed.**
/// The rows are a `LazyVStack` inside a `ScrollView`, and `ImageRenderer` does not lay a lazy
/// container out at all: rendered offscreen, at an unbounded height and at a fixed one, the panel
/// comes out as an empty plate with its shadow and nothing in it. A picture saying the menu is
/// empty, of the feature whose bug was a menu that looked empty, is worse than no picture. The one
/// state that does draw there is the sentence for a query naming nobody, which is the only row on
/// the page outside the scroll view.
///
/// That is the same exclusion `review-comments` and `inspector-tabs` carry in `Snapshot.swift`,
/// for a different reason: those two hold an `NSViewRepresentable`, which `ImageRenderer` paints
/// SwiftUI's yellow placeholder over. Three pages now, two causes, one answer.
///
///     Bloom --snapshot-gallery <dir> --gallery mention-menu
///
/// The bubble the caption sits over cannot be photographed either way: a sent turn is drawn by an
/// `NSViewRepresentable`, so there is no honest still of a captioned bubble and none is claimed.
struct MentionMenuGallery: View {
    private static let people = [
        ComposerAudience.Person(id: CloudUserID("u2"), handle: "sebdd", name: "Seb De Deyne"),
        ComposerAudience.Person(id: CloudUserID("u3"), handle: "alex", name: "Alex Vanderbist"),
        ComposerAudience.Person(id: CloudUserID("u4"), handle: "rias", name: "Rias Van der Veken"),
    ]

    private static func rows(_ query: String) -> [MentionCandidate] {
        MentionAddress.candidates(
            matching: query,
            people: people,
            runningAgent: .claudeCode,
            agentName: AgentKind.claudeCode.label
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            state("@", "Everybody, agent first")
            state("@bl", "The product's own name")
            state("@seb", "A colleague, by handle")
            state("@zz", "Nobody")
        }
        .padding(24)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// One state: what was typed, over the menu it opens.
    ///
    /// The typed text is drawn above rather than in a composer, because the box is the same
    /// `NSTextView` that cannot be photographed here and the thing under review is the list.
    private func state(_ typed: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(caption)
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
            Text(typed)
                .font(Typo.body)
                .foregroundStyle(Palette.textPrimary)
            PersonMentionMenu(
                candidates: Self.rows(String(typed.dropFirst())),
                query: String(typed.dropFirst()),
                selectedIndex: 0,
                onPick: { _ in },
                onHighlight: { _ in }
            )
            .frame(width: 260)
        }
    }
}

extension Gallery {
    /// The registry entry for this page. See `Gallery`.
    static let mentionMenu = Gallery(
        name: "mention-menu",
        title: "Addressing a message",
        size: CGSize(width: 1_220, height: 300),
        needsFocus: false,
        view: { _ in AnyView(MentionMenuGallery()) }
    )
}
