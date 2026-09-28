import SwiftUI

/// The hover of a row in a floating list somebody arrows through: the slash menu, the mention
/// menu, the footer pickers, the quick prompt panel and the search panel.
///
/// Six rows carried the same eight lines: a `@State` for the pointer, a plate that reads it next
/// to the list's selection, and an `.onHover` that wrote the state and then told the list which
/// row the pointer had reached, so that the keyboard highlight follows the pointer. The list is
/// told on the way in and never on the way out: the highlight stays on the last row the pointer
/// entered, the way a menu's does. Six copies of that were six places for the rule to drift.
///
/// **Not `HoverRow`, although it looks like the same thing.** `HoverRow` exists because the
/// inspector's rows read `\.isOnEmphasizedSelection` from their parent and so cannot plate
/// themselves; these rows set their own label colours from `isSelected` and the window's active
/// state, plate themselves happily, and have a list to tell. Folding the two together would give
/// `HoverRow` a callback nothing of its own uses, and give these rows a wrapper they do not need.
///
/// The state lives in the modifier, so a row that only wants the plate holds none. A row that
/// also draws something from the hover, which is `QuickPromptRow` revealing its pencil, keeps its
/// own `@State` and passes it in, so there is still one answer to "is the pointer here".
enum PickerRowPlate {
    /// `rowBackground`, filling the row to its own edges. Whether the list has the keyboard is
    /// the row's decision, because it is the difference between the accent fill and the quiet
    /// one. See `RowBackground`.
    case list(isFocused: Bool)
    /// `searchPanelRowPlate`, inset from the card's edges. See `SearchPanelRowPlate`.
    case searchPanel
}

extension View {
    /// Plates the row for its selection and hover, and calls `onEnter` when the pointer arrives.
    func pickerRowHover(
        isSelected: Bool, plate: PickerRowPlate, onEnter: @escaping @MainActor () -> Void
    ) -> some View {
        modifier(OwnedPickerRowHover(isSelected: isSelected, plate: plate, onEnter: onEnter))
    }

    /// The same, for a row that reads the hover itself as well.
    func pickerRowHover(
        isSelected: Bool,
        plate: PickerRowPlate,
        isHovered: Binding<Bool>,
        onEnter: @escaping @MainActor () -> Void
    ) -> some View {
        modifier(
            PickerRowHover(isSelected: isSelected, plate: plate, isHovered: isHovered, onEnter: onEnter)
        )
    }
}

private struct OwnedPickerRowHover: ViewModifier {
    var isSelected: Bool
    var plate: PickerRowPlate
    var onEnter: @MainActor () -> Void

    @State private var isHovered = false

    func body(content: Content) -> some View {
        content.modifier(
            PickerRowHover(isSelected: isSelected, plate: plate, isHovered: $isHovered, onEnter: onEnter)
        )
    }
}

private struct PickerRowHover: ViewModifier {
    var isSelected: Bool
    var plate: PickerRowPlate
    @Binding var isHovered: Bool
    var onEnter: @MainActor () -> Void

    func body(content: Content) -> some View {
        plated(content)
            .onHover { hovering in
                isHovered = hovering
                if hovering { onEnter() }
            }
    }

    @ViewBuilder
    private func plated(_ content: Content) -> some View {
        switch plate {
        case .list(let isFocused):
            content.rowBackground(isSelected: isSelected, isHovered: isHovered, isFocused: isFocused)
        case .searchPanel:
            content.searchPanelRowPlate(isSelected: isSelected, isHovered: isHovered)
        }
    }
}
