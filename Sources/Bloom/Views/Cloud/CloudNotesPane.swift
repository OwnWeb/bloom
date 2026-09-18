import BloomClient
import BloomCore
import BloomProtocol
import SwiftUI

/// A Cloud workspace's notes: the same pane as a local workspace's, over the machine's copy.
///
/// **The note belongs to the workspace rather than to the Mac reading it.** A local note is a row
/// in this Mac's database, which is the right home when the workspace is a worktree on this disk.
/// A Cloud workspace can be opened from another Mac by somebody else on the team, and a note
/// written here that only this Mac could see would be a scratchpad that disappears depending on who
/// opens the workspace. The machine keeps it, through `notes` and `save_notes`, which put it in the
/// same place the local one lives: the workspace's row in the store beside it.
///
/// Everything drawn is `NotesPage`, exactly as the local pane draws it. What differs is where the
/// text is read from and written to, which is the whole of the difference between the two kinds of
/// workspace and is why this file is short.
struct CloudNotesPane: View {
    var session: CloudWorkspaceSession

    @State private var text = ""
    /// What the machine is known to hold, so a save that would rewrite the same text is skipped.
    @State private var saved = ""
    @State private var hasLoaded = false
    @State private var couldNotLoad = false
    @State private var couldNotSave = false
    @State private var saveTask: Task<Void, Never>?
    @FocusState private var isEditing: Bool

    var body: some View {
        NotesPage(
            text: $text,
            isEditing: $isEditing,
            surfaceID: session.surfaceID,
            workspaceName: session.surfaceName,
            hasLoaded: hasLoaded,
            couldNotLoad: couldNotLoad,
            couldNotSave: couldNotSave,
            hasChanges: WorkspaceNote.needsSave(stored: saved, typed: text),
            onRetryLoad: { Task { await load() } },
            onRetrySave: saveNow
        )
        .onChange(of: text) { _, _ in scheduleSave() }
        .task {
            await load()
            isEditing = true
        }
        .onChange(of: isEditing) { _, editing in if !editing { saveNow() } }
        .focusedValue(\.isTypingProse, isEditing)
        .onDisappear(perform: saveNow)
    }

    // MARK: - Reading and writing over the connection

    /// A machine that will not answer leaves the field disabled and says so, rather than showing a
    /// blank page over a real note and writing the blank version over it on the first keystroke.
    /// The same rule as the local pane's, for the same reason, against a different failure.
    private func load() async {
        guard !hasLoaded else { return }
        do {
            let result = try await session.perform(.notes)
            guard case .text(let stored) = result else {
                couldNotLoad = true
                return
            }
            text = stored
            saved = stored
            couldNotLoad = false
            hasLoaded = true
        } catch {
            couldNotLoad = true
        }
    }

    private func scheduleSave() {
        guard hasLoaded else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: WorkspaceNote.autosaveDelay)
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    private func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        let typed = text
        guard hasLoaded, WorkspaceNote.needsSave(stored: saved, typed: typed) else { return }
        Task { await save() }
    }

    private func save() async {
        let typed = text
        guard WorkspaceNote.needsSave(stored: saved, typed: typed) else { return }
        // Not reported in the notice strip: the pane says it itself, under the text it could not
        // write, which is where somebody who is typing is looking. `saved` is deliberately left
        // alone so the next keystroke tries again. See `WorkspaceNote.unwritable`.
        guard await session.run(.saveNotes(text: typed), reporting: false) == nil else {
            couldNotSave = true
            return
        }
        saved = typed
        couldNotSave = false
    }
}
