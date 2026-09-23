import Testing
@testable import BloomCore

@Suite("When a Cloud workspace's changes may be read")
struct CloudChangesReadinessTests {
    /// A new workspace whose record had not arrived passed the old gate, and its branch diff was
    /// read while the checkout was still being written.
    @Test("a setup state nobody has been told yet holds the read back")
    func unknownHoldsBack() {
        #expect(CloudChangesReadiness.of(setupState: nil) == .unknown)
        #expect(!CloudChangesReadiness.of(setupState: nil).mayRead)
    }

    @Test("pending and running are setting up", arguments: ["pending", "running"])
    func settingUp(state: String) {
        #expect(CloudChangesReadiness.of(setupState: state) == .settingUp)
        #expect(!CloudChangesReadiness.of(setupState: state).mayRead)
    }

    @Test("however setup ended, the worktree may be read", arguments: ["succeeded", "failed", "skipped", "ignored"])
    func ended(state: String) {
        #expect(CloudChangesReadiness.of(setupState: state).mayRead)
    }

    @Test("the gate opening is the moment to read, and nothing else is")
    func opening() {
        #expect(CloudChangesReadiness.opened(from: .unknown, to: .readable))
        #expect(CloudChangesReadiness.opened(from: .settingUp, to: .readable))
        #expect(!CloudChangesReadiness.opened(from: .readable, to: .readable))
        #expect(!CloudChangesReadiness.opened(from: .unknown, to: .settingUp))
        #expect(!CloudChangesReadiness.opened(from: .readable, to: .settingUp))
    }
}
