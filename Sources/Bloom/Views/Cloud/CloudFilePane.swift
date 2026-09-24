import BloomCore
import SwiftUI

/// An unchanged file from a Cloud workspace, with the same file-level bar as a local file.
/// View uses the machine's held text; Edit uses its revision-guarded editor.
struct CloudFilePane: View {
    var session: CloudWorkspaceSession
    var path: String

    @State private var width: CGFloat = 0
    @State private var copyFlash = CopyFlash()
    private let edits = FileEditSession.shared

    private var key: String { session.editorKey(for: path) }
    private var state: SourceEditorState { SourceEditorState.file(key) }
    private var canEdit: Bool { session.capabilities.has(.editFiles) }
    private var mode: FileTabMode {
        FileTabMode.current(
            prefersEditing: state.prefersEditing, prefersPreview: false,
            hasPreview: false, canEdit: canEdit
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: InspectorLayout.gap) {
                FilePathLabel(path: path, width: width)
                UnsavedEditsDot(session: edits, path: key)
                Spacer(minLength: InspectorLayout.tight)
                Button {
                    copyFlash.copy {
                        mode == .edit ? edits.draft(for: key)?.text : session.contents(of: path)
                    }
                } label: {
                    Label(copyFlash.isShowing ? "Copied" : "Copy file",
                          systemImage: copyFlash.isShowing ? "checkmark" : "doc.on.doc")
                }
                .labelStyle(.iconOnly)
                .inspectorBarControl()
                .help("Copy file contents")
                if canEdit {
                    Picker("File view", selection: Binding(
                        get: { mode },
                        set: { state.prefersEditing = $0 == .edit }
                    )) {
                        Text("View").tag(FileTabMode.source)
                        Text("Edit").tag(FileTabMode.edit)
                    }
                    .compactSegmented()
                }
            }
            .controlSize(.small)
            .padding(.horizontal, InspectorLayout.inset)
            .frame(height: InspectorLayout.barHeight)
            .background(Palette.surfaceSunken)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            Hairline()
            if mode == .edit {
                FileEditPane(model: session, path: path, session: edits, onSaved: {
                    session.changes.forgetContents(of: path)
                })
            } else if let text = session.contents(of: path) {
                ScrollView([.vertical, .horizontal]) {
                    Text(text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Metrics.gutter)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.codeBackground)
            } else {
                LoadingView("Reading \((path as NSString).lastPathComponent)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.surface)
        .onAppear { if edits.isDirty(key) { state.prefersEditing = true } }
        .onDisappear { copyFlash.cancel() }
        .background {
            Button("Toggle View and Edit") { state.prefersEditing.toggle() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!canEdit)
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
    }
}

extension CloudWorkspaceSession {
    func filePane(path: String) -> CloudFilePane {
        CloudFilePane(session: self, path: path)
    }
}
