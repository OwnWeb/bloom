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

    /// "Creating the machine" drew "Reading the worktree" in the inspector for as long as the
    /// machine took, because no record meant not knowing, even with runbloom.app saying why.
    @Test("no record while runbloom.app says setting up is setting up")
    func machineBeingMade() {
        #expect(CloudChangesReadiness.of(setupState: nil, workspaceState: "setting_up") == .settingUp)
        #expect(CloudChangesReadiness.of(setupState: nil, workspaceState: "ready") == .unknown)
        #expect(CloudChangesReadiness.of(setupState: "succeeded", workspaceState: "setting_up").mayRead)
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
