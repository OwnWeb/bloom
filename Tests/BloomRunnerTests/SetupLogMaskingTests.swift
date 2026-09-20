import BloomCore
import Testing
@testable import BloomRunner

/// L5 in the review of 19 September 2026: a script run with `set -x` prints the team's keys into
/// a log every viewer reads.
@Suite("What the setup log hides")
struct SetupLogMaskingTests {
    @Test("a team value is masked wherever it appears, the longer of two overlapping first")
    func valuesAreMasked() {
        let hidden = ["sk-live-abcdef123456", "sk-live-abcdef"]
        let line = "+ export STRIPE_KEY=sk-live-abcdef123456 OTHER=sk-live-abcdef"
        #expect(SetupLog.masking(line, hiding: hidden) == "+ export STRIPE_KEY=****** OTHER=******")
    }

    @Test("short values are left alone, so numbers and flags still read")
    func shortValuesStay() async throws {
        let store = try Store(path: SetupTestSupport.directory("setup-mask") + "/bloom.sqlite")
        let log = SetupLog(store: store, workspaceID: WorkspaceID("w"), directory: try SetupTestSupport.directory("setup-mask-steps"))
        await log.hide(["true", "3000", "a-real-secret-value"])
        await log.append("PORT=3000 DEBUG=true TOKEN=a-real-secret-value")
        #expect(await log.text.contains("PORT=3000 DEBUG=true TOKEN=******"))
    }
}
