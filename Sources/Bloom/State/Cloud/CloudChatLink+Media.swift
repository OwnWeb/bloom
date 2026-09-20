import BloomCore
import BloomProtocol
import Foundation

/// Fetching the picture a machine's `media` row names, so it can be drawn from this Mac's disk.
///
/// **Once per picture, kept.** The machine names its copy by the file's digest and never changes
/// it under a row, so a copy fetched once is the picture for good, and scrolling a transcript back
/// past it must not ask the machine again. Kept in this app's caches rather than in memory because
/// a video is drawn by AVKit from a file, and an image drawn from a file is the same path the local
/// `media_show` row takes, so the two rows draw through one view.
///
/// Under the workspace's own folder so two machines with the same file cannot hand each other a
/// copy they never sent, and in the caches directory because every byte of it can be fetched
/// again: a cleared cache is a slower first draw, never a missing picture.
extension CloudChatLink {
    /// Where the picture is on this Mac, or the sentence saying why it is not.
    func media(_ shared: SharedMedia) async -> Result<URL, MediaTrouble> {
        guard let workspaceID else { return .failure(MediaTrouble("This Bloom Cloud workspace is closed.")) }
        let file = Self.mediaFolder(workspaceID).appendingPathComponent(CloudMediaFileName.of(shared.path))
        if FileManager.default.fileExists(atPath: file.path) { return .success(file) }

        let record: DownloadRecord
        do {
            record = try await download(shared.path)
        } catch {
            return .failure(MediaTrouble(error.message))
        }
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try record.data.write(to: file, options: .atomic)
        } catch {
            return .failure(MediaTrouble("Bloom could not keep the file: \(error.localizedDescription)"))
        }
        return .success(file)
    }

    struct MediaTrouble: Error, Equatable {
        let sentence: String
        init(_ sentence: String) { self.sentence = sentence }
    }

    private static func mediaFolder(_ workspaceID: CloudWorkspaceID) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Bloom", isDirectory: true)
            .appendingPathComponent("Cloud media", isDirectory: true)
            .appendingPathComponent(workspaceID.rawValue, isDirectory: true)
    }
}
