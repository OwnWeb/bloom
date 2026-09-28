import SwiftUI

/// The ground every chip in the window stands on: a filled shape, a hairline rim in the border
/// colour, and a hit area of exactly that shape.
///
/// `AttachmentChip`, `SlashCommandChip`, `ReviewCommentChip` and the transcript's suggestion
/// capsule each drew these three layers out by hand, and the three chips in the composer strip
/// promise in their own comments to be built to the same measurements. A promise in a comment
/// cannot stop the drift and one modifier can, which is the argument `AttachmentChip.slot` already
/// won for the icon slot.
///
/// The content shape is part of the plate rather than left to the caller, because a chip is
/// pressed on its rounded ground and not on the square corners outside it, and a chip that set the
/// fill and forgot the shape would take clicks a few points outside what it draws.
///
/// **Unlike `HoverPlate`, hover here replaces the resting fill rather than washing over it.** Every
/// chip did it that way before the two were shared, and the wash is translucent, so layering it
/// here would draw every hovered chip a different colour from the one it had. The move was meant to
/// change no pixel, so the chips keep what they had.
struct ChipPlate<PlateShape: InsettableShape>: ViewModifier {
    var shape: PlateShape
    var fill: Color
    var stroke: Color

    func body(content: Content) -> some View {
        content
            .background { shape.fill(fill) }
            .overlay { shape.strokeBorder(stroke, lineWidth: Metrics.outline) }
            .contentShape(shape)
    }
}

/// The self-tracking form, for a chip whose hover changes nothing but its plate.
private struct HoveringChipPlate<PlateShape: InsettableShape>: ViewModifier {
    var shape: PlateShape
    var rest: Color

    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .modifier(ChipPlate(shape: shape, fill: isHovered ? Palette.hover : rest, stroke: Palette.border))
            .onHover { isHovered = $0 }
    }
}

extension View {
    /// A chip's plate with its fill decided by the caller, for a chip whose ground changes with
    /// more than hover. `AttachmentChip` is the one: inside a sent turn's accent bubble its fill
    /// and rim are both drawn in the bubble's own ink.
    func chipPlate(in shape: some InsettableShape, fill: Color, stroke: Color = Palette.border) -> some View {
        modifier(ChipPlate(shape: shape, fill: fill, stroke: stroke))
    }

    /// A chip's plate lit by a hover flag the caller keeps, because its hover also swaps the icon
    /// for a close control or starts a hover card.
    func chipPlate(
        in shape: some InsettableShape,
        isHovered: Bool,
        rest: Color = Palette.surfaceRaised
    ) -> some View {
        chipPlate(in: shape, fill: isHovered ? Palette.hover : rest)
    }

    /// A chip's plate that tracks the pointer itself.
    func chipPlate(in shape: some InsettableShape, rest: Color = Palette.surfaceRaised) -> some View {
        modifier(HoveringChipPlate(shape: shape, rest: rest))
    }
}
