import SwiftUI
import BloomCore
import UniformTypeIdentifiers

/// The headers are native List section headers, which `onMove` cannot pick up as rows.
/// Dragging one over the other changes only their order, leaving every row inside untouched.
private struct SidebarSectionReorder: ViewModifier {
    let section: SidebarTopSection
    @Binding var order: String
    @Binding var dragging: SidebarTopSection?
    @State private var isDropTarget = false

    private static var type: UTType { UTType(exportedAs: "be.spatie.bloom.sidebar-section") }

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onDrag {
                dragging = section
                let provider = NSItemProvider()
                provider.registerDataRepresentation(
                    forTypeIdentifier: Self.type.identifier, visibility: .all
                ) { completion in
                    completion(Data(section.dragToken.utf8), nil)
                    return nil
                }
                return provider
            }
            .onDrop(of: [Self.type], isTargeted: $isDropTarget) { providers, _ in
                guard !providers.isEmpty, dragging != nil else { return false }
                dragging = nil
                return true
            }
            .onChange(of: isDropTarget) { _, targeted in
                guard targeted, let source = dragging,
                      let next = SidebarSectionOrder.moving(source, onto: section)
                else { return }
                // The dragged header keeps its identity when the rows beneath it move.
                // Entering its new location cannot immediately undo the reorder.
                order = next.rawValue
            }
            .accessibilityHint("Drag onto the other section heading to change their order")
    }
}

extension View {
    func reorderableSection(
        _ section: SidebarTopSection, order: Binding<String>, dragging: Binding<SidebarTopSection?>
    ) -> some View {
        modifier(SidebarSectionReorder(section: section, order: order, dragging: dragging))
    }
}
