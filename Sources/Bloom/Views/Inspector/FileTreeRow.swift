import SwiftUI
import AppKit
import BloomCore

/// One row of the worktree tree: a disclosure chevron or a document icon, the name, and a dot if
/// the agent touched it.
///
/// As with `ChangedFileRow`, the tree paints the selection fill and this row reads it back out of
/// the environment, which is the only way its own body can invert the marks that carry meaning.
struct FileTreeRow: View, Equatable {
    /// On the values, not on `action`, which is a fresh closure on every pass over the tree. See
    /// `ChangedFileRow` for the whole of the reason.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item.node == rhs.item.node
            && lhs.item.depth == rhs.item.depth
            && lhs.isExpanded == rhs.isExpanded
            && lhs.isChanged == rhs.isChanged
            && lhs.containsChanges == rhs.containsChanges
            && lhs.fullPath == rhs.fullPath
            && lhs.canDelete == rhs.canDelete
    }

    var item: FileTreeRowItem
    var isExpanded: Bool
    var isChanged: Bool
    var containsChanges: Bool = false
    var fullPath: String?
    var canDelete: Bool
    var action: () -> Void
    var onDelete: () -> Void
    /// Opens a shell in this row, which only a folder row offers. See `FolderTerminal`.
    var onOpenTerminal: () -> Void
    /// Opens this row as a page in the workspace's browser tab, and in the half a split opens.
    /// Only a file that is a page is offered them, which `LocalPageItems` decides. Closures rather
    /// than the model, so the row keeps comparing on its values alone: see `==` above.
    var onOpenPage: @MainActor () -> Void
    var onSplitPage: @MainActor (SplitAxis) -> Void

    @Environment(\.isOnEmphasizedSelection) private var isOnSelection

    /// The dot marking a file the agent touched. Punctuation, not a badge.
    private static let changedDotSize: CGFloat = 5

    var body: some View {
        Button(action: action) {
            HStack(spacing: InspectorLayout.gap) {
                FileTreeIcon(name: item.node.name, isDirectory: item.node.isDirectory, isExpanded: isExpanded)
                // A directory is one step quieter than a file, said with the hierarchical style so
                // it still inverts on a selected row.
                Text(item.node.name)
                    .font(Typo.body)
                    .foregroundStyle(item.node.isDirectory ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if isChanged {
                    Circle()
                        .fill(isOnSelection ? Palette.selectedEmphasizedText : Palette.warning)
                        .frame(width: Self.changedDotSize, height: Self.changedDotSize)
                        .accessibilityLabel("Changed")
                }
            }
            .treeIndent(depth: item.depth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if !item.node.isDirectory, let fullPath { HoverQuickLook(url: URL(fileURLWithPath: fullPath)) }
        }
        // Folders included: dragging a directory out of a worktree is the same gesture in Finder,
        // and the provider carries whichever of the two this row is.
        .fileDrag(path: fullPath ?? "", enabled: fullPath != nil)
        .contextMenu {
            FileLocationMenuItems(
                path: fullPath,
                relativePath: item.node.path,
                isDirectory: item.node.isDirectory,
                onOpenTerminal: onOpenTerminal,
                onOpenPage: onOpenPage,
                onSplitPage: onSplitPage
            )
            if !item.node.isDirectory, canDelete {
                Divider()
                Button("Delete File", role: .destructive, action: onDelete)
            }
        }
        .help(item.node.path)
        .accessibilityValue(disclosureState)
        .accessibilityInputLabels([item.node.name])
    }

    /// A file has no disclosure state to report, and an empty value is one VoiceOver skips.
    private var disclosureState: String {
        guard item.node.isDirectory else { return "" }
        let state = isExpanded ? "Expanded" : "Collapsed"
        return containsChanges ? "\(state), contains changed files" : state
    }
}
