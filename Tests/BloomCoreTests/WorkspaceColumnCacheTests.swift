import Testing
@testable import BloomCore

struct WorkspaceColumnCacheTests {
    @Test func keepsTheCurrentAndPreviousWorkspace() {
        let first = WorkspaceID("first")
        let second = WorkspaceID("second")
        let third = WorkspaceID("third")

        var columns = WorkspaceColumnCache.visiting(first, in: [])
        columns = WorkspaceColumnCache.visiting(second, in: columns)
        columns = WorkspaceColumnCache.visiting(third, in: columns)

        #expect(columns == [third, second])
    }

    @Test func revisitingMakesAWorkspaceCurrentWithoutDuplicatingIt() {
        let first = WorkspaceID("first")
        let second = WorkspaceID("second")

        let columns = WorkspaceColumnCache.visiting(first, in: [second, first])

        #expect(columns == [first, second])
    }

    @Test func removesAWorkspaceThatNoLongerHasAModel() {
        let first = WorkspaceID("first")
        let second = WorkspaceID("second")

        let columns = WorkspaceColumnCache.removing(first, from: [second, first])

        #expect(columns == [second])
    }

    @Test func keepsRetainedViewsInPlaceWhenRecencyReverses() {
        let first = WorkspaceID("first")
        let second = WorkspaceID("second")

        let columns = WorkspaceColumnCache.stableMembers(
            [first, second], from: [second, first]
        )

        #expect(columns == [first, second])
    }

    @Test func replacesOnlyTheEvictedView() {
        let first = WorkspaceID("first")
        let second = WorkspaceID("second")
        let third = WorkspaceID("third")

        let columns = WorkspaceColumnCache.stableMembers(
            [first, second], from: [third, second]
        )

        #expect(columns == [second, third])
    }
}
