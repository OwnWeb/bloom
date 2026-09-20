import BloomProtocol
import Foundation
import Testing
#if os(Linux)
import Glibc
#endif
@testable import BloomCore

@Suite("RemoteReview", .tags(.git, .security), .scratchDirectory)
struct RemoteReviewTests {
    @Test func changedFilePatchAndCurrentContentsComeFromTheServerWorkspace() async throws {
        let fixture = try await RemoteReviewFixture()
        try fixture.repo.write("new.txt", "created on server\n")
        let changed = try await RemoteReview.changes(workspace: fixture.workspace, scope: .branch)
        #expect(changed.map(\.path) == ["new.txt"])
        let patch = try await RemoteReview.patch(workspace: fixture.workspace, path: "new.txt", scope: .branch)
        #expect(patch.contains("+created on server"))
        let file = try RemoteReview.file(workspace: fixture.workspace, path: "new.txt")
        #expect(file.text == "created on server\n")
    }

    @Test func diffUsesThePinnedSnapshotAfterTheWorkspaceDirectoryIsSwapped() async throws {
        let fixture = try await RemoteReviewFixture()
        try fixture.repo.write("nested/value.txt", "inside snapshot\n")
        let outside = TestScratch.unique("outside-patch")
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try Data("outside private contents\n".utf8).write(to: URL(fileURLWithPath: outside + "/value.txt"))
        let snapshot = try RemoteDiffWorktree(workspace: fixture.workspace, paths: ["nested/value.txt"])
        defer { snapshot.remove() }
        try FileManager.default.moveItem(atPath: fixture.repo.path + "/nested", toPath: fixture.repo.path + "/original")
        try FileManager.default.createSymbolicLink(atPath: fixture.repo.path + "/nested", withDestinationPath: outside)
        let arguments = ["--literal-pathspecs", "diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color", "--", "/dev/null", "nested/value.txt"]
        let diff = try await Git.run(snapshot.arguments(arguments, workspace: fixture.workspace), in: snapshot.path)
        #expect(diff.status == 1)
        #expect(diff.stdout.contains("+inside snapshot"))
        #expect(!diff.stdout.contains("outside private contents"))
        #expect(diff.stdout.contains("b/nested/value.txt"))
    }

    @Test func snapshotRetainsDiffAttributesWithoutChangingTheRealIndex() async throws {
        let fixture = try await RemoteReviewFixture()
        try fixture.repo.write(".gitattributes", "*.txt -diff\n")
        try await fixture.repo.commit("Mark text fixtures as binary")
        let indexPath = URL(fileURLWithPath: fixture.repo.path + "/.git/index")
        let originalIndex = try Data(contentsOf: indexPath)
        try fixture.repo.write("binary.txt", "contents that attributes hide from a text diff\n")
        let patch = try await RemoteReview.patch(workspace: fixture.workspace, path: "binary.txt", scope: .uncommitted)
        #expect(patch.contains("Binary files"))
        #expect(!patch.contains("+contents that"))
        #expect(try Data(contentsOf: indexPath) == originalIndex)
    }

    @Test func aDeletedParentDirectoryStillProducesADeletionPatch() async throws {
        let fixture = try await RemoteReviewFixture()
        try fixture.repo.write("nested/value.txt", "previous contents\n")
        try await fixture.repo.commit("Add nested file")
        try FileManager.default.removeItem(atPath: fixture.repo.path + "/nested")
        let patch = try await RemoteReview.patch(workspace: fixture.workspace, path: "nested/value.txt", scope: .uncommitted)
        #expect(patch.contains("-previous contents"))
        #expect(patch.contains("+++ /dev/null"))
    }

    @Test func pathspecMagicIsTreatedAsALiteralFilename() async throws {
        let fixture = try await RemoteReviewFixture()
        let path = ":(glob)*.txt"
        try fixture.repo.write(path, "literal file\n")
        try fixture.repo.write("other.txt", "do not include this file\n")
        try await fixture.repo.commit("Add filenames")
        try fixture.repo.write(path, "changed literal file\n")
        try fixture.repo.write("other.txt", "unrelated edit\n")
        let patch = try await RemoteReview.patch(workspace: fixture.workspace, path: path, scope: .uncommitted)
        #expect(patch.contains("+changed literal file"))
        #expect(!patch.contains("unrelated edit"))
    }

    @Test func fileReadsRefuseTraversalAndExternalSymlinks() async throws {
        let fixture = try await RemoteReviewFixture()
        let outside = TestScratch.path("outside.txt")
        try Data("private outside contents\n".utf8).write(to: URL(fileURLWithPath: outside))
        try fixture.repo.write("inside.txt", "inside contents\n")
        try FileManager.default.createSymbolicLink(atPath: fixture.repo.path + "/external", withDestinationPath: outside)
        try FileManager.default.createSymbolicLink(atPath: fixture.repo.path + "/internal", withDestinationPath: "inside.txt")
        for path in ["../outside.txt", outside, "external", "nested/../../outside.txt", "\0"] {
            #expect(throws: RemoteFailure.self) { _ = try RemoteReview.file(workspace: fixture.workspace, path: path) }
        }
        let internalFile = try RemoteReview.file(workspace: fixture.workspace, path: "internal")
        #expect(internalFile.text == "inside contents\n")
    }

    @Test func symlinkDiffAndLineCountUseTheLinkInsteadOfItsTargetContents() async throws {
        let fixture = try await RemoteReviewFixture()
        let outside = TestScratch.path("outside.txt")
        try Data("private one\nprivate two\nprivate three\n".utf8).write(to: URL(fileURLWithPath: outside))
        try FileManager.default.createSymbolicLink(atPath: fixture.repo.path + "/link", withDestinationPath: outside)
        let files = try await RemoteReview.changes(workspace: fixture.workspace, scope: .branch)
        let link = try #require(files.first(where: { $0.path == "link" }))
        #expect(link.additions == 1)
        let patch = try await RemoteReview.patch(workspace: fixture.workspace, path: "link", scope: .branch)
        #expect(!patch.contains("private one"))
        #expect(patch.contains(outside))
    }

    @Test func binaryLargeAndSpecialFilesAreRefusedWithoutBlocking() async throws {
        let fixture = try await RemoteReviewFixture()
        try Data([0, 1, 2]).write(to: URL(fileURLWithPath: fixture.repo.path + "/binary"))
        try Data([0xff, 0xfe]).write(to: URL(fileURLWithPath: fixture.repo.path + "/non-utf8"))
        let large = fixture.repo.path + "/large"
        _ = FileManager.default.createFile(atPath: large, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: large))
        try handle.truncate(atOffset: UInt64(RemoteReview.fileLimit + 1))
        try handle.close()
        let fifo = fixture.repo.path + "/fifo"
        let made = mkfifo(fifo, 0o600)
        #expect(made == 0)
        for path in ["binary", "non-utf8", "large", "fifo"] {
            #expect(throws: RemoteFailure.self) { _ = try RemoteReview.file(workspace: fixture.workspace, path: path) }
        }
    }

    @Test func renamedAndDeletedFilesCanStillBeReviewed() async throws {
        let fixture = try await RemoteReviewFixture()
        try fixture.repo.write("old.txt", "keep this content\n")
        try fixture.repo.write("deleted.txt", "remove this content\n")
        try await fixture.repo.commit("Add original files")
        try FileManager.default.moveItem(atPath: fixture.repo.path + "/old.txt", toPath: fixture.repo.path + "/renamed.txt")
        try FileManager.default.removeItem(atPath: fixture.repo.path + "/deleted.txt")
        _ = try await Shell.run("git", ["add", "-A"], cwd: fixture.repo.path)
        let rename = try await RemoteReview.patch(workspace: fixture.workspace, path: "renamed.txt", scope: .uncommitted)
        #expect(rename.contains("rename from old.txt"))
        #expect(rename.contains("rename to renamed.txt"))
        let deletion = try await RemoteReview.patch(workspace: fixture.workspace, path: "deleted.txt", scope: .uncommitted)
        #expect(deletion.contains("-remove this content"))
    }

    @Test func unchangedOrForgedPathsCannotBeRequestedAsDiffs() async throws {
        let fixture = try await RemoteReviewFixture()
        for path in ["README.md", "../outside", "/etc/passwd"] {
            do {
                _ = try await RemoteReview.patch(workspace: fixture.workspace, path: path, scope: .branch)
                Issue.record("Accepted a path that was not a changed workspace file")
            } catch { #expect(error is RemoteFailure) }
        }
    }

    @Test func emptyUntrackedTextIsNotBinary() async throws {
        let fixture = try await RemoteReviewFixture()
        try fixture.repo.write("empty", "")
        let files = try await RemoteReview.changes(workspace: fixture.workspace, scope: .branch)
        let empty = try #require(files.first(where: { $0.path == "empty" }))
        #expect(empty.additions == 0)
        #expect(!empty.isBinary)
    }

    @Test func uncommittedIsOneRowPerPathMeasuredFromHead() async throws {
        let fixture = try await RemoteReviewFixture()
        try fixture.repo.write("layered.txt", "committed\n")
        try await fixture.repo.commit("Add a file to stage over")
        try fixture.repo.write("layered.txt", "staged\n")
        _ = try await Shell.run("git", ["add", "layered.txt"], cwd: fixture.repo.path)
        try fixture.repo.write("layered.txt", "staged\nand edited again\n")
        let files = try await RemoteReview.changes(workspace: fixture.workspace, scope: .uncommitted)
        #expect(files.map(\.path) == ["layered.txt"])
        #expect(files.first?.additions == 2)
        #expect(files.first?.deletions == 1)
        let patch = try await RemoteReview.patch(workspace: fixture.workspace, path: "layered.txt", scope: .uncommitted)
        #expect(patch.contains("-committed"))
        #expect(patch.contains("+and edited again"))
    }

    @Test func largeUntrackedFilesAreListedWithoutBeingRead() async throws {
        let fixture = try await RemoteReviewFixture()
        let large = fixture.repo.path + "/large.txt"
        _ = FileManager.default.createFile(atPath: large, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: large))
        try handle.truncate(atOffset: UInt64(RemoteReview.fileLimit + 1))
        try handle.close()
        let files = try await RemoteReview.changes(workspace: fixture.workspace, scope: .branch)
        let file = try #require(files.first { $0.path == "large.txt" })
        #expect(file.additions == 0)
        #expect(!file.isBinary)
    }

    @Test func recordsSpellTheChangeOut() {
        let changes: [ChangedFile.Change] = [.added, .modified, .deleted, .renamed, .copied, .untracked]
        #expect(changes.map(\.wireName) == ["added", "modified", "deleted", "renamed", "copied", "untracked"])
        let record = ChangedFile(path: "new.txt", oldPath: "old.txt", change: .renamed, additions: 2, deletions: 1)
            .record(contentRevision: "abc")
        #expect(record == ChangedFileRecord(path: "new.txt", oldPath: "old.txt", change: "renamed", additions: 2, deletions: 1, isBinary: false, contentRevision: "abc"))
    }
}

private struct RemoteReviewFixture {
    let repo: TempRepo
    let workspace: Workspace

    init() async throws {
        repo = try await TempRepo()
        workspace = Workspace(repoID: .new(), name: "Review", branch: "main", path: repo.path, baseBranch: "main")
    }
}
