import BloomCore
import Foundation

@MainActor
protocol EditableFiles: Sendable {
    func read(_ key: String) async -> Result<EditableFile, FileEditorError>
    func write(_ text: String, over baseline: EditableFile) async -> Result<EditableFile, FileEditorError>
    /// Whether Edit is worth offering for this file at all, answered without opening it, because
    /// the bar asks it for every file somebody clicks.
    func isEditable(_ key: String) async -> Bool
}

/// A file in a worktree on this Mac, which is `FileEditor` and a background thread.
struct DiskFiles: EditableFiles {
    func read(_ key: String) async -> Result<EditableFile, FileEditorError> {
        await Task.detached(priority: .userInitiated) { () -> Result<EditableFile, FileEditorError> in
            do {
                return .success(try FileEditor.read(key))
            } catch let error as FileEditorError {
                return .failure(error)
            } catch {
                return .failure(.unreadable(path: key, reason: error.localizedDescription))
            }
        }.value
    }

    func write(_ text: String, over baseline: EditableFile) async -> Result<EditableFile, FileEditorError> {
        await Task.detached(priority: .userInitiated) { () -> Result<EditableFile, FileEditorError> in
            do {
                return .success(try FileEditor.write(text, over: baseline))
            } catch let error as FileEditorError {
                return .failure(error)
            } catch {
                return .failure(.unwritable(path: baseline.path, reason: error.localizedDescription))
            }
        }.value
    }

    /// A `stat` and the first bytes of the file, off the main thread: the bar asks this for every
    /// file that is clicked.
    func isEditable(_ key: String) async -> Bool {
        await Task.detached(priority: .utility) { FileEditor.isEditable(key) }.value
    }
}
