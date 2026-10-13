import SwiftUI
import BloomCore

/// A List row takes precedence over a SwiftUI drag gesture on its content. An AppKit hit target
/// over just the title receives the mouse drag before the list can turn it into row selection.
private struct SidebarSectionReorder: ViewModifier {
    let section: SidebarTopSection
    @Binding var order: String
    @State private var verticalOffset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(y: verticalOffset)
            .overlay {
                SectionTitleDragSurface(
                    order: SidebarSectionOrder(rawValue: order) ?? .fallback,
                    onDrag: drag,
                    onEnd: endDrag
                )
            }
            .accessibilityHint("Drag up or down to move this section")
    }

    private func drag(_ translation: CGFloat, from start: SidebarSectionOrder) {
        let next = start.dragging(section, translation: Double(translation))
        verticalOffset = next == start ? translation : 0
        if order != next.rawValue { order = next.rawValue }
    }

    private func endDrag() {
        verticalOffset = 0
    }
}

extension View {
    func reorderableSection(_ section: SidebarTopSection, order: Binding<String>) -> some View {
        modifier(SidebarSectionReorder(section: section, order: order))
    }
}

private struct SectionTitleDragSurface: NSViewRepresentable {
    let order: SidebarSectionOrder
    let onDrag: (CGFloat, SidebarSectionOrder) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> SectionTitleTrackingView {
        let view = SectionTitleTrackingView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: SectionTitleTrackingView, context: Context) {
        nsView.order = order
        nsView.onDrag = onDrag
        nsView.onEnd = onEnd
    }
}

private final class SectionTitleTrackingView: NSView {
    var order = SidebarSectionOrder.fallback
    var onDrag: ((CGFloat, SidebarSectionOrder) -> Void)?
    var onEnd: (() -> Void)?
    private var mouseDownY: CGFloat?
    private var startingOrder: SidebarSectionOrder?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownY = event.locationInWindow.y
        startingOrder = order
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownY, let startingOrder else { return }
        onDrag?(mouseDownY - event.locationInWindow.y, startingOrder)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownY = nil
        startingOrder = nil
        onEnd?()
    }
}
