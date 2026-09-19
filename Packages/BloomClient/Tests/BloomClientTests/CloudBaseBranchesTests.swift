import Testing
@testable import BloomClient

@Suite("The branches a Bloom Cloud workspace can be cut from")
struct CloudBaseBranchesTests {
    @Test("the default branch leads, and a page's names follow without repeating it")
    func defaultFirst() {
        var list = CloudBaseBranches(defaultBranch: "main")
        list.search("")
        #expect(list.load == .loading)
        #expect(list.rows == ["main"], "the default is offered before anything has loaded")
        list.receive(["develop", "main", "release"], next: "cursor-2", for: "")
        #expect(list.rows == ["main", "develop", "release"])
        #expect(list.next == "cursor-2")
        list.loadingMore()
        list.receive(["release", "hotfix"], next: nil, for: "")
        #expect(list.rows == ["main", "develop", "release", "hotfix"])
        #expect(list.load == .loaded)
    }

    /// A branch pushed a moment ago may not be listed yet.
    @Test("a typed name is a row after whatever matched it, when git would take it")
    func typedName() {
        var list = CloudBaseBranches(defaultBranch: "main")
        list.search("feat/new")
        list.receive(["feat/new-login"], next: nil, for: "feat/new")
        #expect(list.rows == ["feat/new-login", "feat/new"])
        #expect(list.isTyped("feat/new"))
        #expect(!list.isTyped("feat/new-login"))

        list.search("bad name")
        #expect(list.typed == nil, "a name git would refuse is not offered")

        list.search("main")
        list.receive(["main"], next: nil, for: "main")
        #expect(list.rows == ["main"], "a listed name is not offered twice")
        #expect(!list.isTyped("main"))
    }

    @Test("the default leaves the list when the search does not match it")
    func defaultFiltered() {
        var list = CloudBaseBranches(defaultBranch: "main")
        list.search("rel")
        list.receive(["release"], next: nil, for: "rel")
        #expect(list.rows == ["release", "rel"])
    }

    @Test("an answer for a search nobody is asking any more is dropped")
    func staleAnswers() {
        var list = CloudBaseBranches(defaultBranch: "main")
        list.search("ma")
        list.search("main")
        list.receive(["maintenance"], next: nil, for: "ma")
        #expect(list.load == .loading)
        #expect(list.rows == ["main"])
        list.fail("Too many requests", for: "ma")
        #expect(list.load == .loading)
        list.fail("runbloom.app could not be reached.", for: "main")
        #expect(list.load == .failed("runbloom.app could not be reached."))
    }
}
