import SwiftUI
import Observation
import BloomCore

/// The buffers behind Edit mode, one per file, for as long as the app is running.
///
/// Drafts are kept per absolute path rather than thrown away when the pane changes, because the
/// pane changes for reasons that have nothing to do with the user being finished: clicking the
/// next file, flipping back to the diff to check something, switching workspace, the file list
/// refreshing underneath. None of those should silently discard typed text, and every one of them
/// tears a view down, which is why this is one store for the launch rather than `@State` on a
/// view that comes and goes.
///
/// Nothing here writes to disk on its own. The only write is `save`, and it is always the user
/// asking.
@MainActor
@Observable
final class FileEditSession {
    /// Absolute paths are unique across workspaces, so one store serves all of them.
    static let shared = FileEditSession()

    private init() {}

    /// One file's editing state. `baseline` is the exact bytes the text was loaded from, which is
    /// what makes a save checkable rather than hopeful.
    typealias Draft = SourceDraft

    enum Status: Equatable {
        case idle
        case loading
        /// The file cannot be edited at all: missing, binary, or too large.
        case unavailable(String)
        /// A save was refused or failed. The draft survives; only the disk was left alone.
        case failed(String)
        case saved
    }

    private(set) var drafts: [String: Draft] = [:]
    private(set) var diskVersions: [String: EditableFile] = [:]
    private var operations: [String: UUID] = [:]
    private(set) var saving: Set<String> = []
    private(set) var status: [String: Status] = [:]

    func status(for path: String) -> Status { status[path] ?? .idle }
    func draft(for path: String) -> Draft? { drafts[path] }
    func isDirty(_ path: String) -> Bool { drafts[path]?.isDirty ?? false }

    /// The buffer the editor binds to. Writing through it can only ever touch a draft that has
    /// already been loaded, so a keystroke arriving during a reload cannot invent one.
    func binding(for path: String) -> Binding<String> {
        Binding(
            get: { self.drafts[path]?.text ?? "" },
            set: { newValue in
                guard var draft = self.drafts[path] else { return }
                draft.text = newValue
                self.drafts[path] = draft
                if case .saved = self.status(for: path) { self.status[path] = .idle }
            }
        )
    }

    func load(path absolutePath: String, from files: any EditableFiles = DiskFiles()) async {
        guard drafts[absolutePath]?.isDirty != true, !saving.contains(absolutePath) else { return }
        // Only the first read shows a spinner. Re-reading a clean draft has something to display
        // the whole time, and flashing the pane empty for it would read as a glitch.
        if drafts[absolutePath] == nil { status[absolutePath] = .loading }

        let operation = UUID()
        operations[absolutePath] = operation
        let outcome = await files.read(absolutePath)
        guard !Task.isCancelled, operations[absolutePath] == operation,
              drafts[absolutePath]?.isDirty != true, !saving.contains(absolutePath) else { return }

        switch outcome {
        case let .success(file):
            drafts[absolutePath] = Draft(baseline: file, text: file.text)
            status[absolutePath] = .idle
        case let .failure(error):
            status[absolutePath] = .unavailable(Self.message(for: error))
        }
    }

    /// Write the draft back, or explain why it was not written.
    ///
    /// The guard lives in `FileEditor.write`, which re-reads the file and refuses when its
    /// contents no longer match what this draft was loaded from. That is the case the agent
    /// causes: it edited the same file while the user was typing, and overwriting it would throw
    /// away work nobody has seen.
    func save(path absolutePath: String, to files: any EditableFiles = DiskFiles()) async {
        guard let draft = drafts[absolutePath], draft.isDirty, !saving.contains(absolutePath) else { return }
        saving.insert(absolutePath)
        defer { saving.remove(absolutePath) }
        let operation = UUID()
        operations[absolutePath] = operation

        let text = draft.text
        let baseline = draft.baseline
        let outcome = await files.write(text, over: baseline)
        guard operations[absolutePath] == operation else { return }

        switch outcome {
        case let .success(saved):
            // Typing during the disk write belongs to the next save, never to the completed one.
            guard var current = drafts[absolutePath] else { return }
            current.didSave(saved)
            drafts[absolutePath] = current
            diskVersions[absolutePath] = nil
            status[absolutePath] = .saved
        case let .failure(error):
            status[absolutePath] = .failed(Self.message(for: error))
        }
    }

    func refresh(path: String, from files: any EditableFiles = DiskFiles()) async {
        guard let baseline = drafts[path]?.baseline, !saving.contains(path) else { return }
        let operation = UUID()
        operations[path] = operation
        let outcome = await files.read(path)
        guard !Task.isCancelled, operations[path] == operation, !saving.contains(path),
              let current = drafts[path], current.baseline == baseline else { return }
        switch outcome {
        case let .success(file):
            if file.text == current.baseline.text { diskVersions[path] = nil; return }
            var refreshed = current
            if !refreshed.acceptDisk(file) { diskVersions[path] = file } else {
                drafts[path] = refreshed
                diskVersions[path] = nil
                status[path] = .idle
            }
        case let .failure(error):
            status[path] = .failed(Self.message(for: error))
        }
    }

    func keepDraftOverDisk(path: String, to files: any EditableFiles = DiskFiles()) async {
        guard let disk = diskVersions[path], var draft = drafts[path], !saving.contains(path) else { return }
        draft.baseline = disk
        drafts[path] = draft
        await save(path: path, to: files)
    }

    /// Throw the draft away and read the file again. Only ever called from an explicit button,
    /// and only after the user has been told what it costs.
    func reload(path absolutePath: String, from files: any EditableFiles = DiskFiles()) async {
        guard !saving.contains(absolutePath) else { return }
        diskVersions[absolutePath] = nil
        drafts[absolutePath] = nil
        status[absolutePath] = .idle
        await load(path: absolutePath, from: files)
    }

    /// Forget a file entirely, for when the file itself is about to stop existing.
    func discard(path absolutePath: String) {
        operations[absolutePath] = nil
        diskVersions[absolutePath] = nil
        drafts[absolutePath] = nil
        status[absolutePath] = nil
    }

    // Typed throws do not survive being caught inside a `Task.detached` closure, which is why the
    // two calls that cross that boundary are wrapped in `DiskFiles` rather than here.

    private static func message(for error: FileEditorError) -> String {
        error.errorDescription ?? "\(error)"
    }
}
