import Testing
@testable import BloomCore

@Suite struct CreateWorkspacePresentationTests {
    @Test func repeatedAskKeepsThePresentedSheet() throws {
        var presentation = CreateWorkspacePresentation()
        presentation.present(repoID: RepoID("first"))
        let first = try #require(presentation.request)

        presentation.present(repoID: nil)
        let repeated = try #require(presentation.request)

        #expect(repeated.id == first.id)
        #expect(repeated.repoID == RepoID("first"))
    }

    @Test func namedAskMovesTheExistingSheetToThatProject() throws {
        var presentation = CreateWorkspacePresentation()
        presentation.present(repoID: RepoID("first"))
        let first = try #require(presentation.request)

        presentation.present(repoID: RepoID("second"))
        let moved = try #require(presentation.request)

        #expect(moved.id == first.id)
        #expect(moved.repoID == RepoID("second"))
    }

    @Test func pullRequestAskIsAnEventOnTheCurrentSheet() throws {
        var presentation = CreateWorkspacePresentation()
        presentation.present(repoID: RepoID("project"), asksForPullRequest: true)
        let opened = try #require(presentation.request)

        presentation.present(repoID: nil, asksForPullRequest: true)
        let repeated = try #require(presentation.request)

        #expect(repeated.id == opened.id)
        #expect(repeated.pullRequestRevision == opened.pullRequestRevision + 1)
    }

    @Test func dismissalClearsModeAndGivesTheNextSheetFreshIdentity() throws {
        var presentation = CreateWorkspacePresentation()
        presentation.present(repoID: RepoID("project"), asksForPullRequest: true)
        let first = try #require(presentation.request)

        presentation.dismiss()
        presentation.present(repoID: RepoID("project"))
        let reopened = try #require(presentation.request)

        #expect(reopened.id != first.id)
        #expect(reopened.pullRequestRevision == 0)
    }
}
