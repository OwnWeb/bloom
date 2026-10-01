import SwiftUI
import BloomCore

/// A List heading owns its drag directly. Its contents follow the pointer until it crosses one
/// row; then the two stable sections exchange places while the pointer is still down.
private struct SidebarSectionReorder: ViewModifier {
    let section: SidebarTopSection
    @Binding var order: String
    @State private var startingOrder: SidebarSectionOrder?
    @State private var verticalOffset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .offset(y: verticalOffset)
            .highPriorityGesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .global)
                    .onChanged { value in
                        let start = startingOrder
                            ?? SidebarSectionOrder(rawValue: order)
                            ?? .fallback
                        if startingOrder == nil { startingOrder = start }
                        let next = start.dragging(
                            section, translation: Double(value.translation.height)
                        )
                        verticalOffset = next == start ? value.translation.height : 0
                        if order != next.rawValue { order = next.rawValue }
                    }
                    .onEnded { _ in
                        verticalOffset = 0
                        startingOrder = nil
                    }
            )
            .accessibilityHint("Drag up or down to move this section")
    }
}

extension View {
    func reorderableSection(_ section: SidebarTopSection, order: Binding<String>) -> some View {
        modifier(SidebarSectionReorder(section: section, order: order))
    }
}
