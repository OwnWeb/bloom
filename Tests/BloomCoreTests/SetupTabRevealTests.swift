import BloomCore
import Testing

/// When a Cloud workspace's setup output is brought forward.
@Suite("Setup tab reveal")
struct SetupTabRevealTests {
    @Test("a state worth watching is revealed once, not on every event that repeats it")
    func oncePerState() {
        var reveal = SetupTabReveal()
        let first = reveal.shouldReveal(for: "running")
        let again = reveal.shouldReveal(for: "running")
        #expect(first)
        #expect(!again)
    }

    @Test("a failure after a run is news of its own")
    func failureAfterRunning() {
        var reveal = SetupTabReveal()
        _ = reveal.shouldReveal(for: "running")
        let failed = reveal.shouldReveal(for: "failed")
        #expect(failed)
    }

    @Test("finished, skipped and nothing at all are not worth pulling a tab forward for")
    func restingStatesAreNot() {
        var reveal = SetupTabReveal()
        let succeeded = reveal.shouldReveal(for: "succeeded")
        let skipped = reveal.shouldReveal(for: "skipped")
        let none = reveal.shouldReveal(for: nil)
        #expect(!succeeded)
        #expect(!skipped)
        #expect(!none)
    }
}
