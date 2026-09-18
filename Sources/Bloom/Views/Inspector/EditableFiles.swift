import BloomClient
import BloomCore
import BloomProtocol
import Foundation

/// Where a file being edited is read from and written back to.
///
/// **The one thing editing a file asks that the two kinds of workspace answer differently.** A
/// worktree on this Mac is `FileEditor`: open the file, read the bytes, write them back atomically
/// having checked the file still holds what the draft was read from. A machine's worktree is the
/// same three steps over the connection, with the machine doing the checking: `file` answers the
/// text and a revision, and `write_file` carries that revision back and is refused where it no
/// longer matches.
///
/// Everything above this is one piece of code: the draft, the dirty mark, the save bar, the
/// refusal, the compare sheet. `FileEditSession` is handed one of these rather than reaching for
/// the disk, which is what let Edit mode open on a Cloud workspace at all.
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

/// A file in a worktree on a machine, read and written over the workspace's connection.
///
/// **The key is the editor's, and the path is the machine's.** Everything above holds a file by
/// `WorkspaceSurface.editorKey`, which for a Cloud workspace names the workspace as well as the
/// file so that two workspaces cannot share a draft. The machine only knows the second half, so
/// this strips the first, and it is the same type that builds the key: a key and its parsing
/// belong to one owner, or they drift.
struct MachineFiles: EditableFiles {
    let session: CloudWorkspaceSession

    func read(_ key: String) async -> Result<EditableFile, FileEditorError> {
        let path = session.relativePath(fromEditorKey: key)
        do {
            let result = try await session.perform(.file(path: path))
            guard case .file(let record) = result else {
                return .failure(.unreadable(path: path, reason: "The Bloom Cloud workspace answered with something else."))
            }
            return .success(Self.file(key: key, record: record))
        } catch {
            return .failure(Self.failure(path: path, error: error))
        }
    }

    func write(_ text: String, over baseline: EditableFile) async -> Result<EditableFile, FileEditorError> {
        let path = session.relativePath(fromEditorKey: baseline.path)
        do {
            let result = try await session.perform(
                // The revision the draft was read at. An empty one can only mean a baseline that
                // never came from a machine, and the machine refuses that rather than writing
                // blind, which is the answer this pane wants: reload and look at what changed.
                .writeFile(path: path, text: text, revision: baseline.revision ?? "")
            )
            guard case .file(let record) = result else {
                return .failure(.unwritable(path: path, reason: "The Bloom Cloud workspace answered with something else."))
            }
            return .success(Self.file(key: baseline.path, record: record))
        } catch {
            return .failure(Self.failure(path: path, error: error))
        }
    }

    /// **Answered without asking, which is the one place this differs from the disk.** The check
    /// on this Mac is a `stat` and a sniff for a NUL byte, and the machine's equivalent would be a
    /// round trip for every file somebody clicks, on a connection where that is a real cost. What
    /// the caller already knows covers the case this is for: the diff says whether the file is
    /// binary, and a file too large or not text is refused by the machine when it is opened, with
    /// its own sentence, in the pane that would have shown it.
    func isEditable(_ key: String) async -> Bool { true }

    /// The machine's answer as the editor holds it: named by the key, stamped by the revision.
    ///
    /// `modifiedAt` is now rather than a time from the machine, which sends none. It is read only
    /// by the sentence a refused save writes, and "when you opened it" is a truer thing to say to
    /// somebody than a date invented here.
    private static func file(key: String, record: TextFileRecord) -> EditableFile {
        EditableFile(
            path: key, text: record.text, modifiedAt: Date(),
            size: record.text.utf8.count, revision: record.revision
        )
    }

    /// The machine's refusal in the editor's own words, so the save bar says the same things it
    /// says over a worktree: somebody else wrote it, it is not there, it is too big, it is not
    /// text. Anything else keeps the machine's sentence, which is more than this could invent.
    private static func failure(path: String, error: WorkspaceConnection.CommandFailure) -> FileEditorError {
        guard case .refused(let wire) = error else {
            return .unreadable(path: path, reason: error.message)
        }
        switch wire.knownCode {
        case .conflict: return .changedOnDisk(path: path, at: Date())
        case .notFound: return .missing(path)
        case .tooLarge: return .tooLarge(path: path, bytes: FileEditor.sizeLimit)
        default: return .unreadable(path: path, reason: wire.message)
        }
    }
}
