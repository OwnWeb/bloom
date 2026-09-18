import SwiftUI

/// Only the conversation composer floats. Creation forms keep their inset field, and both
/// keep the background as the focus target so text selection still belongs to NSTextView.
struct ComposerBox: ViewModifier {
    @Binding var isFocused: Bool
    var isFloating = false
    var isDropTarget = false
    /// The fill the next message will carry, when that is not the ordinary one: terracotta while
    /// the composer is addressed to a person.
    ///
    /// **The composer and the bubble it becomes are one object at two moments.** The owner's
    /// complaint was that addressing a person is invisible until after the message has gone, and a
    /// box that tints to the colour the bubble will be is the whole answer: what you see before you
    /// press Return is what you get after. The design work that settled this caught itself
    /// shipping a composer promising one colour and producing another, which is two objects
    /// wearing one idea, so the value here is the same `Palette.directFill` the bubble uses rather
    /// than a tint chosen to look like it.
    var addressedTint: Color?

    @Environment(\.controlActiveState) private var activeState
    @Environment(\.colorSchemeContrast) private var contrast

    private var isRingVisible: Bool { isFocused && activeState.showsFocusRing }

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: isFloating ? ComposerLayout.corner : Metrics.corner,
            style: .continuous
        )
    }

    func body(content: Content) -> some View {
        let padded = content
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, Metrics.gutter)
            .padding(.bottom, isFloating ? Metrics.spacingWide : Metrics.gutter)
            .background {
                shape
                    .fill(isFloating ? Color.clear : Palette.surfaceSunken)
                    .contentShape(shape)
                    .onTapGesture { isFocused = true }
                    .accessibilityHidden(true)
            }

        if isFloating {
            padded
                // One material for the whole composer. Its controls keep their ordinary styles,
                // and completion menus are attached outside this modifier.
                .glassEffect(addressedTint.map { .regular.tint($0) } ?? .regular, in: shape)
                // The border carries it as well as the material, because glass over a colour is a
                // suggestion of that colour and this has to be unmistakable on the frame before
                // somebody presses Return. Under the focus ring and the drop target, both of which
                // are about what is happening now rather than where the message is going.
                .overlay {
                    if let addressedTint {
                        shape.strokeBorder(addressedTint, lineWidth: 1).allowsHitTesting(false)
                    }
                }
                .overlay {
                    shape.strokeBorder(
                        isDropTarget ? Palette.controlAccent : focusColour,
                        lineWidth: isDropTarget || contrast == .increased ? 2 : 0.5
                    )
                    .opacity(isDropTarget ? 1 : (isRingVisible ? focusOpacity : 0))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
        } else {
            padded
                .overlay {
                    shape.strokeBorder(
                        isDropTarget ? Palette.accent : Palette.border,
                        lineWidth: isDropTarget ? Metrics.outline * 2 : Metrics.outline
                    )
                    .allowsHitTesting(false)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Metrics.corner + 1.5)
                        .strokeBorder(Palette.focusRing, lineWidth: 3)
                        .padding(-1.5)
                        .opacity(isRingVisible ? 1 : 0)
                        .allowsHitTesting(false)
                }
        }
    }

    private var focusColour: Color {
        contrast == .increased ? Palette.focusRing : Palette.textSecondary
    }

    private var focusOpacity: Double { contrast == .increased ? 1 : 0.2 }
}

extension View {
    func composerBox(
        isFocused: Binding<Bool>, isDropTarget: Bool = false, isFloating: Bool = false,
        addressedTint: Color? = nil
    ) -> some View {
        modifier(ComposerBox(
            isFocused: isFocused, isFloating: isFloating, isDropTarget: isDropTarget,
            addressedTint: addressedTint
        ))
    }
}
