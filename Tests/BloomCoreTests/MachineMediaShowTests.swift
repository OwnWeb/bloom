import BloomProtocol
import Foundation
import Testing
@testable import BloomCore

@Suite("media_show on a Bloom Cloud machine", .scratchDirectory)
struct MachineMediaShowTests {
    @Test("old media rows remain readable without the requested marker")
    func legacyMedia() throws {
        let old = Data(#"{"path":"image.png","name":"image.png","caption":"","kind":"image","mime":"image/png","bytes":3}"#.utf8)
        let media = try JSONDecoder().decode(SharedMedia.self, from: old)
        #expect(!media.requested)
    }
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13])

    @Test("a picture is known by its first bytes, whatever it is called")
    func sniffing() {
        #expect(SharedMedia.sniff(Self.png)?.mime == "image/png")
        #expect(SharedMedia.sniff(Data([0xFF, 0xD8, 0xFF, 0xE0]))?.mime == "image/jpeg")
        #expect(SharedMedia.sniff(Data("GIF89a......".utf8))?.mime == "image/gif")
        #expect(SharedMedia.sniff(Data("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8 ".utf8))?.mime == "image/webp")
        #expect(SharedMedia.sniff(Data([0, 0, 0, 0x1C]) + Data("ftypavif".utf8))?.mime == "image/avif")
        #expect(SharedMedia.sniff(Data([0, 0, 0, 0x1C]) + Data("ftypisom".utf8))?.mime == "video/mp4")
        #expect(SharedMedia.sniff(Data([0, 0, 0, 0x14]) + Data("ftypqt  ".utf8))?.mime == "video/quicktime")
        #expect(SharedMedia.sniff(Data([0x1A, 0x45, 0xDF, 0xA3]))?.mime == "video/webm")
        // A document that can carry script, and a secret with a picture's name, are not pictures.
        #expect(SharedMedia.sniff(Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8)) == nil)
        #expect(SharedMedia.sniff(Data(#"{"secret":"s3cret"}"#.utf8)) == nil)
    }

    private func worktree() throws -> Workspace {
        let path = TestScratch.unique("media-worktree")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return Workspace(repoID: RepoID("repo"), name: "Media", branch: "media", path: path, baseBranch: "main")
    }

    @Test("a file anywhere is copied into the ignored scratch folder, once per picture")
    func copying() throws {
        let workspace = try worktree()
        let outside = TestScratch.unique("screenshots")
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        let shot = outside + "/shot.png"
        try Self.png.write(to: URL(filePath: shot))

        let media = try SharedMedia.copy(path: shot, caption: " The login page ", workspace: workspace)
        #expect(media.path.hasPrefix(".bloom/scratch/media/") && media.path.hasSuffix(".png"))
        #expect(media.name == "shot.png")
        #expect(media.caption == "The login page")
        #expect(media.bytes == Self.png.count)
        #expect(try Data(contentsOf: URL(filePath: workspace.path + "/" + media.path)) == Self.png)
        #expect(try String(contentsOfFile: workspace.path + "/.bloom/scratch/.gitignore", encoding: .utf8) == "*\n",
                "the copy never reaches the diff")
        #expect(try SharedMedia.copy(path: shot, caption: "", workspace: workspace).path == media.path)
    }

    @Test("a file that is not a picture, or is too large, is refused and nothing is copied")
    func refusals() throws {
        let workspace = try worktree()
        let disguised = workspace.path + "/workspace.png"
        try Data(#"{"secret":"s3cret"}"#.utf8).write(to: URL(filePath: disguised))
        #expect(throws: RemoteFailure.self) { try SharedMedia.copy(path: "workspace.png", caption: "", workspace: workspace) }

        let large = workspace.path + "/large.png"
        try (Self.png + Data(count: SharedMedia.limit)).write(to: URL(filePath: large))
        #expect(throws: RemoteFailure.self) { try SharedMedia.copy(path: "large.png", caption: "", workspace: workspace) }
        #expect(throws: RemoteFailure.self) { try SharedMedia.copy(path: "missing.png", caption: "", workspace: workspace) }
        #expect(!FileManager.default.fileExists(atPath: workspace.path + "/" + SharedMedia.folder))
    }
}
