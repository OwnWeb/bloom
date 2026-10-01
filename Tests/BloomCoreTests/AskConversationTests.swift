import Testing
import Foundation
@testable import BloomCore

/// The four decisions behind the chat that belongs to no workspace, three of which are values and
/// are therefore worth pinning here rather than in prose.
@Suite("Ask Bloom's conversation", .tags(.persistence), .scratchDirectory)
struct AskConversationTests {
    /// The permission decision, not the tidiness one. Bloom's default mode is `acceptEdits`, and a
    /// chat started in the owner's home directory under it would accept an edit anywhere in that
    /// directory without asking. An empty directory of its own makes every filesystem reach a
    /// reach outside the working directory, which is a reach that asks.
    @Test("it runs in its own directory beside the database, and not in a home directory")
    func directoryIsBesideTheDatabase() {
        let directory = AskConversation.directory(besideDatabaseAt: "/tmp/somewhere/bloom.sqlite")
        #expect(directory == "/tmp/somewhere/Ask")
        #expect(!directory.hasSuffix("bloom.sqlite"))
    }

    /// Beside the database rather than at a fixed path, so the separation between Bloom and Bloom
    /// Dev that every other piece of per-instance state has costs nothing here. Two copies with
    /// two databases get two directories without a second rule to keep in step.
    @Test("two copies of Bloom get two directories")
    func devCopyIsSeparate() {
        let owner = AskConversation.directory(besideDatabaseAt: "/tmp/Bloom/bloom.sqlite")
        let dev = AskConversation.directory(besideDatabaseAt: "/tmp/Bloom Dev/bloom.sqlite")
        #expect(owner != dev)
    }

    @Test("the directory is made, and is empty")
    func directoryIsMadeEmpty() throws {
        let database = TestScratch.unique("ask-cwd") + "/bloom.sqlite"
        try FileManager.default.createDirectory(
            atPath: (database as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )

        let path = try #require(AskConversation.prepareDirectory(besideDatabaseAt: database))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(try FileManager.default.contentsOfDirectory(atPath: path).isEmpty)

        // Made once: a second call over an existing directory answers with it rather than failing.
        #expect(AskConversation.prepareDirectory(besideDatabaseAt: database) == path)
    }

    @Test("a new chat has no workspace and starts with the built-in permission fallback")
    func newSessionStartsWithFallback() {
        let session = AskConversation.newSession()
        #expect(session.workspaceID == nil)
        #expect(session.permissionMode == AppDefaults.fallbackPermissionMode)
        #expect(session.title == AskConversation.title)
        #expect(session.state == .idle)
    }

    @Test("Ask Bloom inherits the permission preference with its model and effort")
    func defaultsReachAskBloom() {
        var defaults = AppDefaults()
        defaults.permissionMode = .acceptEdits
        defaults.planMode = false

        let inWorktree = ComposerDefaults.resolve(repo: RepoSettings(), app: defaults)
        #expect(inWorktree.permissionMode == .acceptEdits)

        let ask = ComposerDefaults.resolve(repo: RepoSettings(), app: defaults, hasWorktree: false)
        #expect(ask.permissionMode == inWorktree.permissionMode)
        #expect(ask.model == inWorktree.model)
        #expect(ask.effort == inWorktree.effort)
    }

    @Test("Claude Code's plan preference also reaches Ask Bloom")
    func planModeReachesAskBloom() {
        var defaults = AppDefaults()
        defaults.planMode = true

        #expect(ComposerDefaults.resolve(repo: RepoSettings(), app: defaults).permissionMode == .plan)
        #expect(
            ComposerDefaults.resolve(repo: RepoSettings(), app: defaults, hasWorktree: false)
                .permissionMode == .plan
        )
    }

    @Test("a new launch applies the current preference, while an in-session choice remains")
    func openingUsesCurrentPreference() {
        var defaults = AppDefaults()
        defaults.permissionMode = .acceptEdits
        #expect(
            AskConversation.modeOnOpening(stored: .auto, defaults: defaults,
                                          agentKind: .codex, isFirstOpenSinceLaunch: true)
                == .acceptEdits
        )
        #expect(
            AskConversation.modeOnOpening(stored: .auto, defaults: defaults,
                                          agentKind: .codex, isFirstOpenSinceLaunch: false)
                == nil
        )
        #expect(
            AskConversation.modeOnOpening(stored: .acceptEdits, defaults: defaults,
                                          agentKind: .codex, isFirstOpenSinceLaunch: true) == nil
        )

        defaults.planMode = true
        #expect(AskConversation.modeOnOpening(stored: .auto, defaults: defaults,
                                               agentKind: .claudeCode, isFirstOpenSinceLaunch: true) == .plan)
        #expect(AskConversation.modeOnOpening(stored: .auto, defaults: defaults,
                                               agentKind: .codex, isFirstOpenSinceLaunch: true) == .acceptEdits)
    }

    /// The menu must explain the wider scope and when the preference returns.
    @Test("the permission menu says what a mode means with no worktree")
    func theMenuSaysWhatAModeMeansHere() throws {
        let inWorktree = ComposerControls(
            session: Session(workspaceID: WorkspaceID("w1")), isFastMode: false, outputStyle: ""
        )
        #expect(inWorktree.hasWorktree)
        // Nothing at all. Every row says what it does on its own line now, so the footnote is
        // left with the one fact that is about this conversation rather than about any row.
        #expect(inWorktree.permissionModeNote == nil)

        let ask = ComposerControls(
            session: AskConversation.newSession(), isFastMode: false, outputStyle: ""
        )
        #expect(!ask.hasWorktree)
        let note = try #require(ask.permissionModeNote)
        #expect(note.contains("whole machine"))
        #expect(note.contains("Bloom next starts"))
        #expect(note.contains("current default"))
    }

    /// The empty state is the first thing the owner sees, and it used to open by listing what this
    /// chat cannot do, in Bloom's own vocabulary ("this chat has no worktree"). It says what to ask
    /// for now. The limits are still said, in the permission menu, which is where they change a
    /// decision rather than merely being true.
    @Test("the opening words offer something rather than apologise")
    func openingWordsOffer() {
        #expect(!AskConversation.emptyHeading.isEmpty)
        #expect(!AskConversation.placeholder.isEmpty)
        #expect(!AskConversation.emptyDetail.contains("cannot"))
        // "worktree" is a word for a thing the reader meets later, if at all.
        #expect(!AskConversation.emptyDetail.lowercased().contains("worktree"))
        #expect(!AskConversation.emptyHeading.lowercased().contains("worktree"))
    }
}
