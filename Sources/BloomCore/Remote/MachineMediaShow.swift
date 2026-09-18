#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// A picture an agent on a Bloom Cloud machine showed, as the `media` row that records it.
///
/// **A reference, never the bytes.** The row names a copy inside the worktree's own git-ignored
/// scratch folder, and a client fetches it with `download`, which is the same door as any other
/// file: a session token for this workspace with `view`, confined to the worktree, at most 8 MB.
/// Nothing about showing a picture opens a way in that the audit in docs/CLOUD-PARITY.md does not
/// already cover.
public struct SharedMedia: Codable, Sendable, Hashable {
    /// Where the copy is, relative to the worktree: what `download` takes.
    public var path: String
    /// The file's own name, which is what a person recognises under the picture.
    public var name: String
    public var caption: String
    /// `image` or `video`.
    public var kind: String
    public var mime: String
    public var bytes: Int

    public init(path: String, name: String, caption: String, kind: String, mime: String, bytes: Int) {
        self.path = path
        self.name = name
        self.caption = caption
        self.kind = kind
        self.mime = mime
        self.bytes = bytes
    }

    /// The folder the copies go in, inside the scratch folder a worktree already ignores.
    public static let folder = WorktreeScratch.generated + "/media"
    public static let limit = RemoteFileOperations.transferLimit

    /// What a file is, read from its first bytes rather than from its name.
    ///
    /// **From the bytes, because the name is the agent's to choose.** A file called `shot.png` that
    /// is really the machine's `workspace.json` is refused here, so showing something can never be
    /// a way to hand a viewer a file that is not a picture. **No SVG**: it is a document that can
    /// carry script, and a client that opened one on its own rather than as an image would run it.
    public static func sniff(_ data: Data) -> (kind: String, mime: String, ext: String)? {
        let head = [UInt8](data.prefix(16))
        func starts(_ bytes: [UInt8], at offset: Int = 0) -> Bool {
            head.count >= offset + bytes.count && Array(head[offset..<offset + bytes.count]) == bytes
        }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return ("image", "image/png", "png") }
        if starts([0xFF, 0xD8, 0xFF]) { return ("image", "image/jpeg", "jpg") }
        if starts(Array("GIF87a".utf8)) || starts(Array("GIF89a".utf8)) { return ("image", "image/gif", "gif") }
        if starts(Array("RIFF".utf8)), starts(Array("WEBP".utf8), at: 8) { return ("image", "image/webp", "webp") }
        if starts([0x1A, 0x45, 0xDF, 0xA3]) { return ("video", "video/webm", "webm") }
        if starts(Array("ftyp".utf8), at: 4), head.count >= 12 {
            switch String(decoding: head[8..<12], as: UTF8.self) {
            case "avif", "avis": return ("image", "image/avif", "avif")
            case "qt  ": return ("video", "video/quicktime", "mov")
            default: return ("video", "video/mp4", "mp4")
            }
        }
        return nil
    }

    /// Copies the file an agent named where a client can fetch it, and answers the row to write.
    ///
    /// **Copied, not pointed at.** The agent's file may be overwritten by the next screenshot, and
    /// a row that pointed at it would show the newer picture under the older message. The copy is
    /// named by its digest, so showing the same picture twice stores it once.
    public static func copy(path: String, caption: String, workspace: Workspace) throws -> SharedMedia {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.hasPrefix("/") ? trimmed : (workspace.path as NSString).appendingPathComponent(trimmed)
        guard let handle = FileHandle(forReadingAtPath: source) else {
            throw RemoteFailure.notFound("There is no file at \(trimmed).")
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: limit + 1)) ?? Data()
        guard data.count <= limit else {
            throw RemoteFailure(.tooLarge, "\(trimmed) is larger than 8 MB. Show a smaller or compressed copy.")
        }
        guard let type = sniff(data) else {
            throw RemoteFailure.invalid("\(trimmed) is not a PNG, JPEG, GIF, WebP or AVIF image, or an MP4, MOV or WebM video.")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let copy = "\(folder)/\(digest).\(type.ext)"
        // The folder's own ignore file, written through the same descriptor walk, so a copy never
        // shows up in the diff or a commit however the project ignores things.
        _ = try WorkspaceFileAccess(workspace: workspace, path: WorktreeScratch.generated + "/.gitignore", creatingParents: true)
            .create(Data("*\n".utf8), allowExisting: true)
        _ = try WorkspaceFileAccess(workspace: workspace, path: copy, creatingParents: true).create(data, allowExisting: true)
        return SharedMedia(path: copy, name: (trimmed as NSString).lastPathComponent,
                           caption: caption.trimmingCharacters(in: .whitespacesAndNewlines),
                           kind: type.kind, mime: type.mime, bytes: data.count)
    }
}

/// `media_show` on a Bloom Cloud machine: the same name and arguments an agent has on a Mac, so it
/// reaches for the same tool wherever it runs, and a different way of getting the picture to a
/// person, because the person's window is somewhere else.
public struct MachineMediaShowTool: BridgeToolHandling {
    public init() {}

    public let roles: Set<BridgeRole> = [.workspace]

    public let tool = BridgeTool(
        name: MediaShowToolName.show,
        description: """
            Show an image or a video inline in this chat, where the people working with you see \
            it without opening anything. Use it whenever what you have to say is a picture: a \
            screenshot you just took, a generated image, a chart, a screen recording. Reading an \
            image file tells YOU what is in it; this is what puts it in front of them.

            The file can be anywhere on this machine, a screenshot in a temporary folder included. \
            It is copied into this workspace's git-ignored scratch folder, so it never lands in \
            the diff. PNG, JPEG, GIF, WebP and AVIF images and MP4, MOV and WebM videos, up to \
            8 MB; anything else is refused, and so is SVG.

            'path' is workspace-relative or absolute. 'caption' is optional and should be one \
            short sentence that adds context not obvious from the picture.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("The image or video file to show."),
                ]),
                "caption": .object([
                    "type": .string("string"),
                    "description": .string("An optional short caption."),
                ]),
            ]),
            "required": .array([.string("path")]),
        ])
    )

    public func call(_ request: MCPRequest, as identity: BridgeIdentity, store: Store) async -> BridgeToolResult {
        guard let workspaceID = identity.workspaceID, let sessionID = identity.sessionID else {
            return .failure("Only an agent working in a chat of this workspace can show something in it.")
        }
        let path = request.stringParam("path")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else { return .failure("media_show needs a non-empty 'path'.") }
        let caption = request.stringParam("caption") ?? ""
        do {
            guard let workspace = try await store.workspace(id: workspaceID) else {
                return .failure(RemoteFailure.shuttingDown.message)
            }
            let media = try SharedMedia.copy(path: path, caption: caption, workspace: workspace)
            _ = try await store.appendNext(sessionID: sessionID, kind: .media, payload: try JSONEncoder().encode(media))
            let what = media.kind == "video" ? "video" : "image"
            return .init(text: "Shown in this chat as \(media.name). Everybody looking at the chat sees the \(what); "
                + "say what it shows only if that adds something.")
        } catch let failure as RemoteFailure {
            return .failure(failure.message)
        } catch {
            return .failure("\(path) could not be shown.")
        }
    }
}
