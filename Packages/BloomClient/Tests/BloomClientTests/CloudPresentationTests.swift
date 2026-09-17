@testable import BloomClient
import BloomProtocol
import Foundation
import Testing

@Suite struct CloudWorkspaceNoticesTests {
    private func item(_ id: String, _ state: String, role: String? = "owner", excerpt: String? = nil) -> CloudWorkspaceItem {
        CloudWorkspaceItem(id: id, teamID: "t", name: "Workspace \(id)", branch: "b", state: state, role: role,
                           summary: excerpt.map { CloudWorkspaceSummary(lastMessage: .init(excerpt: $0)) })
    }

    @Test func theFirstReadingSaysNothing() {
        #expect(CloudWorkspaceNotices.between(previous: nil, current: [item("a", "waiting_for_input")]).isEmpty)
    }

    @Test func transitionsIntoWaitingFinishedAndFailedAreReported() {
        let before = [item("a", "running"), item("b", "running"), item("c", "setting_up"), item("d", "idle")]
        let after = [item("a", "waiting_for_input", excerpt: "Should it retry?"), item("b", "idle"), item("c", "setup_failed"), item("d", "idle")]
        let notices = CloudWorkspaceNotices.between(previous: before, current: after)
        #expect(notices.map(\.kind) == [.needsInput, .finished, .setupFailed])
        #expect(notices.first?.detail == "Should it retry?")
    }

    @Test func idleWithoutHavingRunIsNotAFinishedTurn() {
        #expect(CloudWorkspaceNotices.between(previous: [item("a", "setting_up")], current: [item("a", "idle")]).isEmpty)
    }

    @Test func workspacesTheReaderIsNotInAndNewOnesAreQuiet() {
        let notices = CloudWorkspaceNotices.between(
            previous: [item("a", "running", role: nil)],
            current: [item("a", "waiting_for_input", role: nil), item("new", "setup_failed")]
        )
        #expect(notices.isEmpty)
    }

    @Test func aWorkspaceCreatedHereIsWatchedFromItsFirstReading() {
        let notices = CloudWorkspaceNotices.between(previous: [], current: [item("new", "setup_failed")], watching: ["new"])
        #expect(notices.map(\.kind) == [.setupFailed])
    }
}

@Suite struct CloudWorkspaceStatusTests {
    @Test func anIdleWorkspaceIsAsleepOrReadyByItsMachine() {
        let asleep = CloudWorkspaceItem(id: "a", teamID: "t", name: "n", branch: "b", state: "idle", summary: CloudWorkspaceSummary(awake: false))
        let awake = CloudWorkspaceItem(id: "a", teamID: "t", name: "n", branch: "b", state: "idle", summary: CloudWorkspaceSummary(awake: true))
        #expect(CloudWorkspaceStatus(item: asleep) == .asleep)
        #expect(CloudWorkspaceStatus(item: awake) == .idle)
    }

    @Test func setupSaysWhichStep() {
        let item = CloudWorkspaceItem(id: "a", teamID: "t", name: "n", branch: "b", state: "setting_up",
                                      summary: CloudWorkspaceSummary(setup: .init(state: "running", step: "prepare")))
        #expect(CloudWorkspaceStatus(item: item).phrase == "Setting up: preparing the machine")
    }
}

@Suite struct PendingOpeningPromptTests {
    private let controls = ComposerControlsRecord(agent: "claude", model: "claude-opus-5", effort: "high", permissionMode: "acceptEdits", interactionMode: "build")

    @Test func opensAChatFirstThenSendsIntoIt() {
        var prompt = PendingOpeningPrompt(workspaceID: "w", text: "Fix the queue", controls: controls)
        let first = prompt.nextOperation
        #expect(first.operation == .newChat(controls: controls))
        #expect(first.commandID == prompt.chatCommandID)
        prompt.chatID = "c1"
        #expect(prompt.nextOperation.operation == .send(chatID: "c1", text: "Fix the queue"))
        #expect(prompt.nextOperation.commandID == prompt.sendCommandID)
    }

    @Test func survivesBeingWrittenAndDropsStaleOnes() {
        let now = Date()
        let fresh = PendingOpeningPrompt(workspaceID: "w1", text: "a", controls: controls, createdAt: now)
        let stale = PendingOpeningPrompt(workspaceID: "w2", text: "b", controls: controls, createdAt: now.addingTimeInterval(-2 * 24 * 60 * 60))
        let stored = PendingOpeningPrompts(prompts: ["w1": fresh, "w2": stale]).encoded
        let read = PendingOpeningPrompts.decode(stored, now: now)
        #expect(read.prompts.keys.sorted() == ["w1"])
        #expect(read.prompts["w1"]?.sendCommandID == fresh.sendCommandID)
    }
}

@Suite struct CloudBranchNameTests {
    @Test(arguments: ["freek/queue-retries", "fix-123", "a.b/c"])
    func goodNamesPass(name: String) {
        #expect(CloudBranchName.problem(name) == nil)
    }

    @Test(arguments: ["", "-x", "a..b", "a b", "a~b", "x.lock", "a/", "a//b", "a/.b", "a@{b", "x."])
    func badNamesSayWhy(name: String) {
        #expect(CloudBranchName.problem(name) != nil)
    }

    @Test func aSuggestionIsASlugUnderThePrefix() {
        #expect(CloudBranchName.suggestion(for: "Queue retries, again!", prefix: "freek") == "freek/queue-retries-again")
        #expect(CloudBranchName.suggestion(for: "   ", prefix: "freek") == "")
    }
}
