import BloomCore
import BloomProtocol
import SwiftUI

/// What changed in a Cloud workspace: the files on the left, the selected file's diff on the right,
/// drawn with the same line view the local review uses.
struct CloudChangesPane: View {
    var session: CloudWorkspaceSession

    var body: some View {
        @Bindable var changes = session.changes
        HSplitView {
            VStack(spacing: 0) {
                Picker("Scope", selection: $changes.scope) {
                    Text("Branch").tag(BloomProtocol.DiffScope.branch)
                    Text("Uncommitted").tag(BloomProtocol.DiffScope.uncommitted)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(Metrics.spacingWide)
                List(selection: $changes.selectedPath) {
                    ForEach(changes.files, id: \.path) { file in
                        HStack {
                            Text(file.path)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer()
                            if !file.isBinary {
                                Text("+\(file.additions)").foregroundStyle(Palette.positive)
                                Text("−\(file.deletions)").foregroundStyle(Palette.negative)
                            }
                        }
                        .font(.callout)
                        .tag(Optional(file.path))
                    }
                }
                .overlay {
                    if changes.files.isEmpty, !changes.isLoading {
                        Text(changes.problem ?? "No changes")
                            .foregroundStyle(Palette.textSecondary)
                            .padding()
                    }
                }
            }
            .frame(minWidth: 220, idealWidth: 280, maxWidth: 420)

            CloudDiffView(diff: changes.diff, path: changes.selectedPath)
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await changes.refresh() }
    }
}

private struct CloudDiffView: View {
    var diff: FileDiff?
    var path: String?

    var body: some View {
        if let diff {
            GeometryReader { geometry in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if diff.isBinary {
                            Text("A binary file changed.").foregroundStyle(Palette.textSecondary).padding()
                        }
                        ForEach(Array(diff.hunks.enumerated()), id: \.offset) { _, hunk in
                            Text(hunk.header)
                                .font(.caption.monospaced())
                                .foregroundStyle(Palette.textTertiary)
                                .padding(.vertical, Metrics.spacingSmall)
                                .padding(.horizontal, Metrics.spacingWide)
                            ForEach(hunk.lines) { line in
                                DiffLineView(line: line, language: Language.detect(path: path ?? ""), width: geometry.size.width)
                            }
                        }
                    }
                }
            }
        } else {
            Text(path == nil ? "Select a file" : "Reading the diff…")
                .foregroundStyle(Palette.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
