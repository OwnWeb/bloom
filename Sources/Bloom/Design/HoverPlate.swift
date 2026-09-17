import SwiftUI

/// The fill a small control shows under the pointer, and nowhere else.
///
/// About ten controls each wrote this out by hand: a `@State` flag, an `onHover` writing it, and a
/// rounded rectangle filled with `Palette.hover` or clear. Nothing about those copies was a
/// decision, and the one place a decision was hiding shows why they should not drift apart.
/// `DiffExpanderView` had its hover swapped in for the band's own fill, and because the hover tint
/// is a translucent wash, hovering made the strip lighter than its resting state instead of
/// darker. So the wash here is always drawn OVER the resting fill, never instead of it, and a
/// caller with a ground of its own gets that for free.
///
/// Being active is different, and replaces the wash rather than sitting under it. A selected row or
/// a switched-on picker is already saying more than hover does, and the originals all drew the
/// selection grey alone whether or not the pointer was on it.
///
/// Two forms. The plain one owns its hover, which is what most controls want. The other is handed
/// the flag, for the controls whose hover also drives something else (a tint on the label, a
/// popover that holds the plate lit) or is tracked on a view the plate is not applied to, such as a
/// `Menu` whose label is where the fill has to be drawn.
struct HoverPlate<PlateShape: Shape>: ViewModifier {
    var shape: PlateShape
    var rest: Color
    var isActive: Bool
    var activeFill: Color
    /// Nil when the plate tracks the pointer itself.
    var isHovered: Bool?

    @State private var ownHover = false

    func body(content: Content) -> some View {
        if isHovered == nil {
            plated(content).onHover { ownHover = $0 }
        } else {
            plated(content)
        }
    }

    private func plated(_ content: Content) -> some View {
        content.background {
            ZStack {
                shape.fill(rest)
                shape.fill(wash)
            }
        }
    }

    private var wash: Color {
        if isActive { return activeFill }
        return (isHovered ?? ownHover) ? Palette.hover : .clear
    }
}

extension View {
    /// A hover fill in `shape` that tracks the pointer itself. See `HoverPlate`.
    func hoverPlate(
        in shape: some Shape,
        rest: Color = .clear,
        isActive: Bool = false,
        activeFill: Color = Palette.selected
    ) -> some View {
        modifier(
            HoverPlate(shape: shape, rest: rest, isActive: isActive, activeFill: activeFill, isHovered: nil)
        )
    }

    /// A hover fill in a rounded rectangle that tracks the pointer itself.
    func hoverPlate(
        cornerRadius: CGFloat,
        rest: Color = .clear,
        isActive: Bool = false,
        activeFill: Color = Palette.selected
    ) -> some View {
        hoverPlate(
            in: RoundedRectangle(cornerRadius: cornerRadius),
            rest: rest,
            isActive: isActive,
            activeFill: activeFill
        )
    }

    /// A hover fill in `shape` driven by a flag the caller keeps, for a caller that reads it too.
    func hoverPlate(
        in shape: some Shape,
        isHovered: Bool,
        rest: Color = .clear,
        isActive: Bool = false,
        activeFill: Color = Palette.selected
    ) -> some View {
        modifier(
            HoverPlate(
                shape: shape, rest: rest, isActive: isActive, activeFill: activeFill, isHovered: isHovered
            )
        )
    }

    /// A hover fill in a rounded rectangle driven by a flag the caller keeps.
    func hoverPlate(
        cornerRadius: CGFloat,
        isHovered: Bool,
        rest: Color = .clear,
        isActive: Bool = false,
        activeFill: Color = Palette.selected
    ) -> some View {
        hoverPlate(
            in: RoundedRectangle(cornerRadius: cornerRadius),
            isHovered: isHovered,
            rest: rest,
            isActive: isActive,
            activeFill: activeFill
        )
    }
}
