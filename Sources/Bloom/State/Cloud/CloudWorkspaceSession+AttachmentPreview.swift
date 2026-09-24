import BloomCore
import BloomProtocol
import Foundation

struct CloudAttachmentPreviewFailure: LocalizedError {
    let sentence: String

    var errorDescription: String? { sentence }
}

extension CloudWorkspaceSession {
    /// Fetches one attachment through the same workspace-scoped download used by the file pane.
    /// The path is hashed before it becomes a local filename, while its extension stays available
    /// to Quick Look. An attachment's UUID path is stable after upload, so another hover can reuse
    /// the copy without sending the image across the connection again.
    func attachmentPreview(path: String) async throws -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let folder = caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Bloom", isDirectory: true)
            .appendingPathComponent("Cloud attachments", isDirectory: true)
            .appendingPathComponent(id.rawValue, isDirectory: true)
        let digest = RemoteFileOperations.revision(Data(path.utf8))
        let ext = (path as NSString).pathExtension.lowercased()
        let safeExtension = !ext.isEmpty && ext.utf8.count <= 12
            && ext.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
        let file = folder.appendingPathComponent(digest + (safeExtension ? "." + ext : ""))

        if FileManager.default.fileExists(atPath: file.path) { return file }

        let result: OperationResult
        do {
            result = try await perform(.download(path: path))
        } catch {
            throw CloudAttachmentPreviewFailure(sentence: error.message)
        }

        guard case .download(let record) = result, record.path == path else {
            throw CloudAttachmentPreviewFailure(sentence: "The machine did not send this file.")
        }

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try record.data.write(to: file, options: .atomic)
        } catch {
            throw CloudAttachmentPreviewFailure(sentence: "Bloom could not keep the preview: \(error.localizedDescription)")
        }

        return file
    }
}
