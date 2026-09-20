import Testing
@testable import BloomCore

@Suite("Cloud project icon load ownership")
struct CloudProjectIconLoadStateTests {
    private let bloom = CloudProjectIconLoadState.Key(
        teamID: CloudTeamID("spatie"), projectID: CloudProjectID("bloom")
    )

    @Test("duplicate repository names in different authorities never share state")
    func duplicateNamesStaySeparate() {
        let elsewhere = CloudProjectIconLoadState.Key(
            teamID: CloudTeamID("personal"), projectID: CloudProjectID("bloom")
        )
        var state = CloudProjectIconLoadState()
        let first = state.begin(key: bloom, url: "https://runbloom.test/spatie/bloom/1")
        let second = state.begin(key: elsewhere, url: "https://runbloom.test/personal/bloom/1")

        let firstLanded = state.finish(first, as: .artwork)
        let secondLanded = state.finish(second, as: .permanentFallback)
        #expect(firstLanded)
        #expect(secondLanded)
        #expect(state.status(for: bloom, url: first.url) == .artwork)
        #expect(state.status(for: elsewhere, url: second.url) == .fallback)
    }

    @Test("a replacement revision rejects a late answer from the old URL")
    func replacementRejectsStaleCompletion() {
        var state = CloudProjectIconLoadState()
        let old = state.begin(key: bloom, url: "https://runbloom.test/icon/4")
        let replacement = state.begin(key: bloom, url: "https://runbloom.test/icon/5")

        let oldLanded = state.finish(old, as: .artwork)
        let replacementLanded = state.finish(replacement, as: .artwork)
        #expect(!oldLanded)
        #expect(replacementLanded)
        #expect(state.status(for: bloom, url: old.url) == .absent)
        #expect(state.status(for: bloom, url: replacement.url) == .artwork)
    }

    @Test("reset and removal prevent an in-flight answer from repopulating the cache")
    func resetRejectsLateCompletion() {
        var state = CloudProjectIconLoadState()
        let removed = state.begin(key: bloom, url: "https://runbloom.test/icon/1")
        state.clear(bloom)
        let removedLanded = state.finish(removed, as: .artwork)
        #expect(!removedLanded)

        let signedOut = state.begin(key: bloom, url: "https://runbloom.test/icon/2")
        state.reset()
        let signedOutLanded = state.finish(signedOut, as: .artwork)
        #expect(!signedOutLanded)
    }

    @Test("only transient failure advances a retry on the normal poll")
    func retriesOnlyTransientFailure() {
        var state = CloudProjectIconLoadState()
        let transient = state.begin(key: bloom, url: "https://runbloom.test/icon/1")
        let transientLanded = state.finish(transient, as: .transientFailure)
        let retried = state.retryTransient(key: bloom, url: transient.url)
        #expect(transientLanded)
        #expect(retried)
        #expect(state.retryRevision(for: bloom) == 1)

        let broken = state.begin(key: bloom, url: "https://runbloom.test/icon/2")
        let brokenLanded = state.finish(broken, as: .permanentFallback)
        let retriedBroken = state.retryTransient(key: bloom, url: broken.url)
        #expect(brokenLanded)
        #expect(!retriedBroken)
        #expect(state.retryRevision(for: bloom) == 1)
    }
}
