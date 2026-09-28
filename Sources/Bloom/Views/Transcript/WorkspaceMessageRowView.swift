import SwiftUI
import BloomCore

/// A message from another workspace, in the chat it was sent to.
///
/// **On the right, with the owner's own turns**, because the right hand side of this transcript
/// means "said to this agent", and this was: the owner's words and another workspace's arrive the
/// same way, as a turn the agent answers.
///
/// **The owner's bubble, in another colour, and nothing more.** Same shape, same measure, same
/// padding and the same tail; what tells the two apart is the Starfish fill and one line above
/// saying who it is from. It was a pale periwinkle plate with a coloured initial, a project and a
/// chat name above, and an "Open" link and a disclosure below, which made it look like a different
/// kind of object rather than the same one from somebody else. See `Palette.workspaceMessage` for
/// why the colour moved.
///
/// **Cut to five lines.** It was drawn whole however long, on the argument that this is what the
/// agent here is answering and the reader should be able to read all of it. A brief for another
/// workspace runs to a dozen paragraphs as readily as to a sentence, and whole it filled the pane
/// and pushed what this agent did about it off the bottom, which is the opposite of that argument.
/// Five rather than the sending chat's three because this is the side the message is read on. See
/// `CutBubbleText` for the cut, and `WorkspaceMessageSentRowView` for the other end of it.
///
/// **No raw envelope.** Under every message sat "Show full prompt", which revealed `sent`: the
/// same words again, inside Bloom's fence and its instructions for answering. The boilerplate is
/// Bloom's rather than the sender's, so a reader of this row learns nothing from it, and it made
/// the long message problem twice as long. `CrewMessageRowView` keeps its envelope, because a
/// subagent's brief is wrapped in the orchestrator's own words rather than in ours.
///
/// Queued, it is the same bubble unfilled with a dotted edge, which is what the owner's own queued
/// turn looks like, and it can be deleted the way that one can. It cannot be edited or steered:
/// the words are not the owner's to change. See `PendingTurnRowView`.
struct WorkspaceMessageRowView: View {
    var message: CrewMessage
    var isWaiting = false
    /// The queue's one sentence, on the last message waiting. See `PendingTurnRowView.caption`.
    var holdSentence: String?
    var onDelete: () -> Void = {}

    /// Read here for the reason `UserTurnRowView` reads it: a pane narrowing then invalidates the
    /// bubbles and not every tool row.
    @Environment(\.transcriptBubbleWidth) private var bubbleWidth

    @State private var isExpanded = false
    /// Whether the message is longer than the cut, answered by `CutBubbleText`.
    @State private var isCut = false
    @State private var isPointedAt = false

    /// `PendingTurnRowView`'s dots, so both queued bubbles are edged the same way.
    private static let dots = StrokeStyle(lineWidth: Metrics.outline, dash: [2, 3])

    /// Enough for most messages to be whole, and for a long one to say what it is about.
    private static let collapsedLines = 5

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: UserTurnRowView.inset)

            VStack(alignment: .trailing, spacing: TranscriptLayout.tight) {
                WorkspaceMessageOrigin(end: message.route, direction: .from)
                bubble
                caption
            }
        }
        .padding(.horizontal, TranscriptLayout.inset)
        .padding(.vertical, TranscriptLayout.inset)
        .onHover { isPointedAt = $0 }
    }

    private var bubble: some View {
        CappedWidth(width: bubbleWidth?.cap ?? UserTurnRowView.uncappedFallback) {
            CutBubbleText(
                text: message.text,
                lines: Self.collapsedLines,
                ink: isWaiting ? Palette.textSecondary : Palette.workspaceMessageInk,
                // Queued, the bubble is an outline with nothing behind it but the transcript.
                fill: isWaiting ? Palette.surface : Palette.workspaceMessageFill,
                isExpanded: isExpanded,
                isCut: $isCut
            )
        }
        .padding(.bottom, OutgoingBubbleShape.tailDrop)
        .background {
            if isWaiting {
                OutgoingBubbleShape(cornerRadius: UserTurnRowView.corner)
                    .strokeBorder(Palette.workspaceMessage, style: Self.dots)
            } else {
                OutgoingBubbleShape(cornerRadius: UserTurnRowView.corner)
                    .fill(Palette.workspaceMessageFill)
            }
        }
    }

    /// "Show all" is not hidden until the pointer arrives, the way "Show full prompt" was. That one
    /// revealed evidence nobody needed on the way past; this one is the only way to read the rest
    /// of a message the row has cut, and an affordance that is the only route to something has to
    /// be visible to be one.
    @ViewBuilder
    private var caption: some View {
        if isWaiting || isCut {
            HStack(spacing: Metrics.gutter) {
                if isWaiting, let holdSentence {
                    Text(holdSentence).foregroundStyle(Palette.textTertiary)
                }
                if isCut {
                    Button(isExpanded ? "Show less" : "Show all") { isExpanded.toggle() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.textTertiary)
                        .pointerStyle(.link)
                }
                if isWaiting {
                    Button("Delete", action: onDelete)
                        .buttonStyle(.plain)
                        .foregroundStyle(isPointedAt ? Palette.link : Palette.textTertiary)
                        .pointerStyle(.link)
                        .help("Takes this message back out of the queue. It is not sent, and the workspace that sent it is told.")
                }
            }
            .font(Typo.caption)
        }
    }
}
