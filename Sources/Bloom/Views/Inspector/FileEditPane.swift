import SwiftUI
import BloomCore

/// Edit mode: the file itself, editable, with the save guard underneath it.
///
/// The bar along the bottom is not decoration. It is the only place the user finds out that a
/// save was refused because the agent had already rewritten the file, and the only way back from
/// that: reload, look at what the agent did, and redo the edit on top of it.
///
/// A path rather than a `ChangedFile`, because the two ways into a file are the diff of one the
/// agent touched and the worktree tree, and the tree opens files git has never heard of. Editing
/// is a question about bytes on disk either way, so the pane only ever needed the path.
struct FileEditPane<Model: WorkspaceSurface>: View {
    let model: Model
    /// Relative to the workspace's worktree, the way every path in the inspector is.
    let path: String
    let session: FileEditSession
    /// Called after a save lands, for a pane whose other half is now showing stale text.
    var onSaved: () -> Void = {}
    var isEditable = true
    var absolutePathOverride: String?

    @Environment(\.colorScheme) private var colorScheme

    /// The Discard button's question.
    @State private var isConfirmingReload = false
    /// The same question, asked after the comparison sheet's "Use disk version". The sheet's own
    /// button is gone by then, so the question hangs off Compare, the control that opened it.
    @State private var isConfirmingDiskVersion = false
    /// Set by "Use disk version" and read once the sheet has finished closing. A popover asked for
    /// while its window still has a sheet going away is a presentation fighting a dismissal.
    @State private var wantsDiskVersion = false

    private var absolutePath: String {
        absolutePathOverride ?? model.editorKey(for: path)
    }

    private var state: SourceEditorState { SourceEditorState.file(absolutePath) }
    @State private var comparing = false

    private var filename: String { (path as NSString).lastPathComponent }

    private var isDirty: Bool { session.isDirty(absolutePath) }

    var body: some View {
        Group {
            switch session.status(for: absolutePath) {
            case .loading:
                LoadingView("Reading the file")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .unavailable(reason):
                EmptyStateView(
                    glyph: "doc.badge.gearshape",
                    title: isEditable ? "Cannot edit this file" : "Cannot read this file",
                    message: reason
                )
            default:
                editor
            }
        }
        .background(Palette.surface)
        .focusedValue(\.saveAction, isEditable ? SaveAction(subject: absolutePath, isEnabled: isDirty && !session.saving.contains(absolutePath), perform: save) : nil)
        .focusedValue(\.isTypingProse, isEditable)
        .onDisappear { state.navigationTask?.cancel() }
        .task(id: absolutePath) {
            await session.load(path: absolutePath, from: model.editableFiles)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                await session.refresh(path: absolutePath, from: model.editableFiles)
            }
        }
        .sheet(isPresented: $comparing, onDismiss: {
            guard wantsDiskVersion else { return }
            wantsDiskVersion = false
            isConfirmingDiskVersion = true
        }, content: { comparison })
    }

    /// The worktree behind this file, or nil for a file on a machine.
    ///
    /// **What the two kinds of workspace genuinely differ on inside this pane, and it is not the
    /// editing.** The tools bar and every lookup under it need a language server rooted in a
    /// worktree on this Mac and a chat to ask about a symbol in, which a Cloud workspace has
    /// neither of. `offersSourceLookup` already says so for the diff; this is the same answer for
    /// the editor, and what is left is a text view that reads and writes a file, which is the
    /// whole of Edit mode.
    private var worktree: WorkspaceModel? { model.composerWorkspace }

    @ViewBuilder
    private var editor: some View {
        if session.draft(for: absolutePath) != nil {
            VStack(spacing: 0) {
                if let worktree {
                    SourceTools(model: worktree, path: path, state: state)
                    Hairline()
                }
                SourceEditor(
                    text: session.binding(for: absolutePath),
                    language: state.languageOverride ?? Language.detect(path: path),
                    colorScheme: colorScheme,
                    isEditable: isEditable,
                    editorState: state,
                    onOpenReference: { reference, offset, newTab in
                        guard let worktree else { return }
                        SourceActions.open(reference, at: offset, path: path, model: worktree, state: state, newTab: newTab)
                    },
                    onDefinition: { offset in
                        guard let worktree else { return }
                        SourceActions.definition(at: offset, path: path, model: worktree, state: state)
                    },
                    onReferences: { offset in
                        guard let worktree else { return }
                        SourceActions.references(at: offset, path: path, model: worktree, state: state)
                    },
                    onNavigateSymbol: { offset, newTab in
                        guard let worktree else { return }
                        SourceActions.navigate(at: offset, path: path, model: worktree, state: state, newTab: newTab)
                    },
                    onAsk: {
                        guard let worktree else { return }
                        SourceActions.ask(path: path, model: worktree, state: state)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Hairline()
                if let message = state.message {
                    HStack {
                        Text(message).font(Typo.caption).textSelection(.enabled)
                        Spacer()
                        Button("Dismiss") { state.message = nil }
                    }.padding(InspectorLayout.inset)
                }
                if session.diskVersions[absolutePath] != nil {
                    HStack {
                        Text("Changed on disk. Your edits are safe.").font(Typo.caption)
                        Spacer()
                        Button("Compare") { comparing = true }
                            .modifier(reloadConfirmation($isConfirmingDiskVersion))
                    }.padding(InspectorLayout.inset)
                }
                if isEditable { footer } else if case let .failed(reason) = session.status(for: absolutePath) {
                    Text(reason).font(Typo.caption).foregroundStyle(Palette.negative).padding(InspectorLayout.inset)
                }
            }
        } else {
            LoadingView("Reading the file")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: InspectorLayout.gap) {
            statusLabel

            Spacer(minLength: InspectorLayout.tight)

            if isDirty {
                Button("Discard") { isConfirmingReload = true }
                    .disabled(session.saving.contains(absolutePath))
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Throw away your unsaved edits and read the file again")
                    .modifier(reloadConfirmation($isConfirmingReload))
            }

            Button("Save", action: save)
                .controlSize(.small)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!isDirty || session.saving.contains(absolutePath))
        }
        .padding(.horizontal, InspectorLayout.inset)
        .frame(height: InspectorLayout.barHeight)
        .background(Palette.surfaceSunken)

    }

    private var comparison: some View {
        VStack(spacing: Metrics.spacing) {
            Text("\(filename) changed on disk").font(Typo.bodyEmphasis)
            HSplitView {
                VStack {
                    Text("Your draft")
                    SourceEditor(text: session.binding(for: absolutePath),
                                 language: state.languageOverride ?? Language.detect(path: path), colorScheme: colorScheme)
                }
                VStack {
                    Text("Current file on disk")
                    SourceEditor(text: .constant(session.diskVersions[absolutePath]?.text ?? ""),
                                 language: state.languageOverride ?? Language.detect(path: path), colorScheme: colorScheme,
                                 isEditable: false)
                }
            }
            HStack {
                Button("Keep editing") { comparing = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use disk version") {
                    wantsDiskVersion = true
                    comparing = false
                }
                Button("Save my version over disk") {
                    Task {
                        await session.keepDraftOverDisk(path: absolutePath, to: model.editableFiles)
                        if case .saved = session.status(for: absolutePath) {
                            comparing = false
                            model.forgetHeldDiff(for: path)
                            await model.refreshChanges()
                            onSaved()
                        }
                    }
                }
                .disabled(session.diskVersions[absolutePath] == nil || session.saving.contains(absolutePath))
            }
            if case let .failed(reason) = session.status(for: absolutePath) {
                Text(reason).foregroundStyle(Palette.negative).font(Typo.caption)
            }
        }.padding(Metrics.inset).frame(width: 950, height: 580)
    }

    /// Asks before the file on disk replaces the draft, as a popover on the control that asked.
    ///
    /// Escape keeps the edits and Return does nothing, which `ConfirmationPopover` holds for every
    /// confirmation built on it. See the archive confirmation in `RootView` for why no cancel
    /// button in this app carries `.keyboardShortcut(.defaultAction)`.
    private func reloadConfirmation(_ isPresented: Binding<Bool>) -> DiscardConfirmationModifier {
        let path = absolutePath
        let session = session
        return DiscardConfirmationModifier(
            isPresented: isPresented,
            title: "Discard your edits to \(filename)?",
            message: { "The file on disk replaces what you typed. There is no undo for this." },
            onConfirm: { Task { await session.reload(path: path, from: model.editableFiles) } }
        )
    }

    /// A save changes the worktree, so the file list's counts and the diff behind this pane are
    /// both stale the moment it lands.
    private func save() {
        Task {
            await session.save(path: absolutePath, to: model.editableFiles)
            guard case .saved = session.status(for: absolutePath) else { return }
            // Including whatever the review pane is holding for this file, which is a picture of
            // the bytes that have just been replaced. See `WorkspaceModel.forgetHeldDiff`.
            model.forgetHeldDiff(for: path)
            await model.refreshChanges()
            onSaved()
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch session.status(for: absolutePath) {
        case let .failed(reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(Typo.caption)
                .foregroundStyle(Palette.negative)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        case .saved where !isDirty:
            Label("Saved", systemImage: "checkmark.circle")
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
        default:
            Text(isDirty ? "Unsaved changes" : "No changes")
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
        }
    }
}

extension WorkspaceModel {
    /// The file itself, editable, which is what Edit mode in a diff shows.
    ///
    /// A view built by the workspace rather than by `DiffView`, because the workspace is what
    /// knows where the bytes are: this Mac's disk here, the machine's connection for a Cloud
    /// workspace. It is the same pane over both, which it was not: it took a `WorkspaceModel` and
    /// read the file itself, and the sentence saying a Cloud workspace could not be edited was
    /// true only because of that. See `EditableFiles`.
    func editorPane(path: String, session: FileEditSession) -> FileEditPane<WorkspaceModel> {
        FileEditPane(model: self, path: path, session: session)
    }
}
