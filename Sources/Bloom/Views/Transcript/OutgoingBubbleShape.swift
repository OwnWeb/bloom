import SwiftUI

/// A single outline shared by sent and queued messages. The tail has its own layout space, so
/// it never changes the text's padding or relies on drawing beyond the row's measured bounds.
///
/// **One set of curves, mirrored, rather than two sets to keep in step.** A message from somebody
/// else sits on the left of the transcript, and its tail has to point the other way or the shape
/// reads as flipped rather than placed. Hand writing the mirror image of nine control points is
/// how the two sides come to differ by half a point at the next adjustment; reflecting the path
/// about the middle of its own bounds cannot.
struct OutgoingBubbleShape: InsettableShape {
    static let tailDrop: CGFloat = 5

    var cornerRadius: CGFloat
    /// Which side the tail is on, which is which side of the transcript the bubble sits on.
    var tail: HorizontalEdge = .trailing
    private var insetAmount: CGFloat = 0

    init(cornerRadius: CGFloat, tail: HorizontalEdge = .trailing) {
        self.cornerRadius = cornerRadius
        self.tail = tail
    }

    func path(in bounds: CGRect) -> Path {
        let drawn = trailingPath(in: bounds)
        guard tail == .leading else { return drawn }
        // x' = minX + maxX - x, which is a reflection about the vertical centre line of the same
        // bounds, so the mirrored shape occupies exactly the rectangle the original did.
        return drawn.applying(
            CGAffineTransform(translationX: bounds.minX + bounds.maxX, y: 0).scaledBy(x: -1, y: 1)
        )
    }

    private func trailingPath(in bounds: CGRect) -> Path {
        let rect = bounds.insetBy(dx: insetAmount, dy: insetAmount)
        guard rect.width > 0, rect.height > Self.tailDrop else { return Path() }
        let right = rect.maxX
        let bottom = rect.maxY - Self.tailDrop
        let radius = max(0, min(cornerRadius - insetAmount, (right - rect.minX) / 2, (bottom - rect.minY) / 2))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: right - radius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: right, y: rect.minY + radius), control: CGPoint(x: right, y: rect.minY))
        path.addLine(to: CGPoint(x: right, y: bottom - radius))
        // Round the side first, then let the tail grow from underneath it. Its tip stays inside
        // the body's right edge, rather than making the side flare out beyond the bubble.
        path.addCurve(
            to: CGPoint(x: right - radius * 0.35, y: bottom - radius * 0.25),
            control1: CGPoint(x: right, y: bottom - radius * 0.5),
            control2: CGPoint(x: right - radius * 0.25, y: bottom - radius * 0.35)
        )
        path.addCurve(
            to: CGPoint(x: right - radius * 0.35, y: rect.maxY),
            control1: CGPoint(x: right - radius * 0.6, y: bottom + Self.tailDrop * 0.1),
            control2: CGPoint(x: right - radius * 0.42, y: bottom + Self.tailDrop * 0.6)
        )
        path.addCurve(
            to: CGPoint(x: right - radius, y: bottom),
            control1: CGPoint(x: right - radius * 0.45, y: rect.maxY),
            control2: CGPoint(x: right - radius * 0.85, y: bottom + Self.tailDrop * 0.1)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: bottom - radius), control: CGPoint(x: rect.minX, y: bottom))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> Self {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}
