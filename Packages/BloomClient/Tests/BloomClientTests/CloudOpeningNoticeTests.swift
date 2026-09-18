import Testing
import BloomProtocol
@testable import BloomClient

@Suite("What a Cloud workspace says while its machine is being made")
struct CloudOpeningNoticeTests {
    private func setup(_ state: String, step: String? = nil) -> SetupRecord {
        SetupRecord(state: state, step: step)
    }

    /// The screen the owner met: a machine being made, a repository about to be cloned, and a
    /// notice whose subject was the queue.
    @Test("Before the machine has said anything, it says what is happening and how long")
    func theFirstMinute() {
        let notice = CloudOpeningNotice.of(setup: nil, log: "", heldPrompt: "open the browser pane")
        #expect(CloudOpeningNotice.title == "Setting up your workspace")
        #expect(notice?.message == "Your first message goes as soon as it is ready: “open the browser pane”")
        #expect(notice?.progress == "Its machine is being made. This takes a few minutes the first time.")
        // With nothing waiting there is room for the second sentence on its own line instead.
        let alone = CloudOpeningNotice.of(setup: setup("pending"), log: "", heldPrompt: nil)
        #expect(alone?.message == "This takes a few minutes the first time.")
        #expect(alone?.progress == "Its machine is being made.")
    }

    @Test("Once there is a step, the step is the live line")
    func theStepIsTheState() {
        let notice = CloudOpeningNotice.of(setup: setup("running", step: "clone"), log: "", heldPrompt: nil)
        #expect(notice?.progress == "Cloning the repository.")
        // The two that used to be invisible, and a step this version has never heard of.
        #expect(CloudOpeningNotice.of(setup: setup("running", step: "git"), log: "", heldPrompt: nil)?.progress
            == "Configuring git.")
        #expect(CloudOpeningNotice.of(setup: setup("running", step: "seeding"), log: "", heldPrompt: nil)?.progress
            == "Seeding.")
    }

    /// The machine writes a true sentence when a run starts again or a step goes quiet, and a
    /// client writing a parallel one would be keeping two things in step for ever.
    @Test("The machine's own newest sentence wins, and its step heading is not said twice")
    func theMachinesOwnWords() {
        let restarted = """
        [bloom] Configuring git.
        [bloom] Starting again: this machine stopped while it was setting up.
        """
        #expect(CloudOpeningNotice.of(setup: setup("running", step: "git"), log: restarted, heldPrompt: nil)?.progress
            == "Starting again: this machine stopped while it was setting up.")
        // The heading alone is the step the live line is already showing.
        #expect(CloudOpeningNotice.of(setup: setup("running", step: "git"), log: "[bloom] Configuring git.", heldPrompt: nil)?
            .progress == "Configuring git.")
    }

    /// A finished, failed or skipped setup is the transcript row's business. A second account of
    /// it in the middle of an empty pane is the duplication this type exists to remove.
    @Test("Once setup has an outcome there is nothing to say here")
    func nothingOnceItIsDone() {
        #expect(CloudOpeningNotice.of(setup: setup("succeeded"), log: "", heldPrompt: nil) == nil)
        #expect(CloudOpeningNotice.of(setup: setup("failed"), log: "", heldPrompt: "hello") == nil)
        #expect(CloudOpeningNotice.of(setup: setup("skipped"), log: "", heldPrompt: nil) == nil)
        // And a local workspace, which has no setup record and nothing waiting, draws its own.
        #expect(CloudOpeningNotice.of(setup: nil, log: "", heldPrompt: nil) == nil)
    }
}
