import BloomCore
import SwiftUI

/// A Cloud workspace's review tab: the changed files on the left, the chosen file's diff beside
/// them.
///
/// **The list is the app's own** (`ChangedFileList`, generic over `WorkspaceReviewSurface`), so the
/// rows, the counts, the filter, the read ticks and the context menus are the ones a local
/// workspace has. The diff on the right is still drawn here rather than by `DiffView`: that view
/// carries review comments, the in-place editor and the revert, which are the next slice's work.
/// See the plan in docs/REMOTE-WORKSPACES.md.
struct CloudReviewTab: View {
    var session: CloudWorkspaceSession
    @State private var diff: FileDiff?
    @State private var problem: String?

    var body: some View {
        HSplitView {
            ChangedFileList(model: session)
                .frame(minWidth: 220, idealWidth: 300, maxWidth: 460)
            diffPane
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: session.selectedFilePath) { await readPatch() }
        .task(id: session.changesGeneration) { await readPatch() }
        .task { await session.refreshChanges() }
    }

    @ViewBuilder
    private var diffPane: some View {
        if let problem {
            EmptyStateView(glyph: "exclamationmark.triangle", title: "Could not read the diff", message: problem)
        } else if let diff, let path = session.selectedFilePath {
            GeometryReader { geometry in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if diff.isBinary {
                            Text("A binary file changed.")
                                .foregroundStyle(Palette.textSecondary)
                                .padding()
                        }
                        ForEach(Array(diff.hunks.enumerated()), id: \.offset) { _, hunk in
                            Text(hunk.header)
                                .font(.caption.monospaced())
                                .foregroundStyle(Palette.textTertiary)
                                .padding(.vertical, Metrics.spacingSmall)
                                .padding(.horizontal, Metrics.spacingWide)
                            ForEach(hunk.lines) { line in
                                DiffLineView(line: line, language: Language.detect(path: path), width: geometry.size.width)
                            }
                        }
                    }
                }
            }
        } else {
            EmptyStateView(
                glyph: "plusminus",
                title: session.selectedFilePath == nil ? "Nothing selected" : "Reading the diff…",
                message: session.selectedFilePath == nil
                    ? "Choose a file to see what changed in it."
                    : "Reading it from this Cloud workspace."
            )
        }
    }

    private func readPatch() async {
        guard let path = session.selectedFilePath,
              let file = session.changedFiles.first(where: { $0.path == path }) else {
            diff = nil
            return
        }
        do {
            diff = DiffParser.parse(try await session.readPatch(for: file)).first
            problem = nil
        } catch {
            problem = error.localizedDescription
            diff = nil
        }
    }
}
