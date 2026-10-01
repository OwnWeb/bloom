import SwiftUI
import BloomCore

/// The headers are native List section headers, which `onMove` cannot pick up as rows.
/// Dragging one over the other changes only their order, leaving every row inside untouched.
private struct SidebarSectionReorder: ViewModifier {
    let section: SidebarTopSection
    @Binding var order: String

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .draggable(section.dragToken)
            .dropDestination(for: String.self) { items, _ in
                guard let token = items.first,
                      let source = SidebarTopSection(dragToken: token),
                      let next = SidebarSectionOrder.moving(source, onto: section)
                else { return false }
                order = next.rawValue
                return true
            } isTargeted: { targeted in
                guard targeted else { return }
                // There are exactly two top sections. Move the other one as soon as its drag
                // enters this heading, so the full sections travel while the pointer is down.
                let source: SidebarTopSection = section == .work ? .conversations : .work
                guard let next = SidebarSectionOrder.moving(source, onto: section) else { return }
                order = next.rawValue
            }
            .accessibilityHint("Drag onto the other section heading to change their order")
    }
}

extension View {
    func reorderableSection(_ section: SidebarTopSection, order: Binding<String>) -> some View {
        modifier(SidebarSectionReorder(section: section, order: order))
    }
}
