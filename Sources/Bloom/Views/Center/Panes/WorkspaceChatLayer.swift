import SwiftUI
import BloomCore

struct WorkspaceChatLayer: View {
    var transcript: TranscriptModel
    @Bindable var model: WorkspaceModel

    @State private var sideOrigin: SideConversation.Snapshot?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isSideConversationVisible: Bool {
        model.sideConversations[transcript.session.id]?.isVisible == true
    }

    /// Grows out of the button it hangs off, a little, as a popover does. Only a fade under Reduce
    /// Motion, and with the animation dropped there as well, as `ComposerDock` does for its pill.
    private func sideConversationTransition(_ placement: SideConversationPlacement) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        let pivot = UnitPoint(
            x: placement.frame.width > 0 ? (placement.tailX ?? placement.frame.width) / placement.frame.width : 1,
            y: 1
        )
        return .scale(scale: 0.96, anchor: pivot).combined(with: .opacity)
    }

    var body: some View {
        Color.clear
            .overlay(alignment: .topLeading) { originPill }
            // Dressed as a popover off the side conversation button, and deliberately not a
            // `.popover`. A side conversation is long lived: its turn runs for minutes and stops to
            // ask for approvals while the owner goes on clicking and selecting text in the main
            // transcript. A transient popover closes on the first click outside it and takes key
            // focus when it opens, so it would be dismissed by exactly the work it is meant to sit
            // beside. As an overlay it stays until Escape or its close button. See
            // `SideConversationPlacement` for where it goes and where its tail points.
            .overlayPreferenceValue(SideConversationButtonAnchor.self) { anchor in
                GeometryReader { geometry in
                    if let state = model.sideConversations[transcript.session.id], state.isVisible {
                        let placement = SideConversationPlacement(
                            pane: geometry.size,
                            anchor: anchor.map { geometry[$0] },
                            cornerRadius: SideConversationView.corner
                        )
                        SideConversationView(parent: transcript, state: state, model: model, tailX: placement.tailX)
                            .frame(width: placement.frame.width, height: placement.frame.height)
                            // Before the offset, so the scale pivots on the tail in the card's own
                            // bounds rather than on a point in the pane's corner.
                            .transition(sideConversationTransition(placement))
                            .offset(x: placement.frame.minX, y: placement.frame.minY)
                    }
                }
                .animation(reduceMotion ? nil : Motion.pane, value: isSideConversationVisible)
            }
            .task(id: transcript.session.id) {
                let origin = try? await model.store?.sideConversationSnapshot(sessionID: transcript.session.id)
                guard !Task.isCancelled else { return }
                sideOrigin = origin
            }
    }

    @ViewBuilder
    private var originPill: some View {
        if let origin = sideOrigin, transcript.session.sideConversationParentID == nil {
            Button {
                WorkspaceTabsStore.shared.reveal(.chat(origin.parentID), in: model)
            } label: {
                Label("From \(origin.title)", systemImage: "arrow.turn.up.left")
                    .font(.caption)
                    .padding(8)
                    .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(!model.sessions.contains { $0.id == origin.parentID })
            .padding(8)
        }
    }
}
