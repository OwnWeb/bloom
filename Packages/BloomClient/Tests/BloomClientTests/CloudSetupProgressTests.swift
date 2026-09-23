import Foundation
import Testing
import BloomProtocol
@testable import BloomClient

@Suite("A new Cloud workspace's build, as steps")
struct CloudSetupProgressTests {
    private func progress(
        _ state: String?, step: String? = nil, log: String = "", isConnected: Bool = true,
        isEnabled: Bool = true, note: String? = nil, failureCode: String? = nil
    ) -> CloudSetupProgress? {
        CloudSetupProgress.of(
            setup: state.map { SetupRecord(state: $0, step: step, note: note, isEnabled: isEnabled, failureCode: failureCode) },
            log: log, isConnected: isConnected, repository: "spatie/there-there.app"
        )
    }

    private func states(_ progress: CloudSetupProgress?) -> [CloudSetupProgress.StepState] {
        progress?.steps.map(\.state) ?? []
    }

    @Test("Before the machine exists, the first step is the one alive")
    func machineBeingMade() {
        let made = progress(nil, isConnected: false)
        #expect(made?.steps.map(\.label) == [
            "Creating the machine", "Connecting to the machine", "Cloning spatie/there-there.app",
            "Running the setup script", "Starting services",
        ])
        #expect(states(made) == [.current, .todo, .todo, .todo, .todo])
        #expect(made?.canStop == false)
        #expect(made?.title == "Setting up the workspace")
    }

    @Test("Connected with no record, or a record still pending, is connecting")
    func connecting() {
        #expect(states(progress(nil)) == [.done, .current, .todo, .todo, .todo])
        #expect(states(progress("pending")) == [.done, .current, .todo, .todo, .todo])
    }

    /// The machine's seven steps fold into the five a person would name, `resume` included: it
    /// ran for a minute after the setup script in the recording, and a list without it lied.
    @Test("Each of the machine's steps lands in its phase")
    func machineStepsFold() {
        for step in ["environment", "git", "clone"] {
            #expect(states(progress("running", step: step)) == [.done, .done, .current, .todo, .todo])
        }
        for step in ["prepare", "setup"] {
            #expect(states(progress("running", step: step)) == [.done, .done, .done, .current, .todo])
        }
        for step in ["resume", "services"] {
            #expect(states(progress("running", step: step)) == [.done, .done, .done, .done, .current])
        }
        #expect(progress("running", step: "setup")?.canStop == true)
    }

    @Test("A workspace created without setup has no script steps")
    func withoutSetup() {
        let ids = progress("running", step: "clone", isEnabled: false)?.steps.map(\.id)
        #expect(ids == [.machine, .connect, .clone])
    }

    @Test("Finished, skipped and ignored setups are the transcript row's, not the card's")
    func outcomesAreNotCards() {
        #expect(progress("succeeded") == nil)
        #expect(progress("skipped") == nil)
        #expect(progress("ignored") == nil)
    }

    /// The recorded run: a setup script that took two and a half minutes under one label. What
    /// moves under the label is the newest heading and the newest line of output after it.
    @Test("Under the current step: its newest heading and the newest line printed after it")
    func activityUnderTheStep() {
        let log = """
        [bloom] Running the prepare script.
        ==> Installing system packages
            installing php8.5-cli php8.5-bcmath
            Installing system packages took 80s
        [bloom] Running the setup script.

        ==> Starting databases, installing Composer and bun dependencies
            started databases
            started composer
        """
        let running = progress("running", step: "setup", log: log)
        #expect(running?.activity == "Starting databases, installing Composer and bun dependencies")
        #expect(running?.lastOutput == "started composer")
    }

    @Test("A heading that only repeats the step's label is not said twice")
    func noRepeatedHeading() {
        let cloning = progress("running", step: "clone", log: "[bloom] Cloning the repository.\n")
        #expect(cloning?.activity == nil)
        // Prepare is a script of its own inside "Running the setup script", so it is worth a line.
        let preparing = progress("running", step: "prepare", log: "[bloom] Running the prepare script.\n")
        #expect(preparing?.activity == "Running the prepare script")
        // And the machine's own steps inside the clone phase say which one it is on.
        let git = progress("running", step: "git", log: "[bloom] Reading the team's environment.\n[bloom] Configuring git.\n")
        #expect(git?.activity == "Configuring git")
    }

    @Test("Only a progress bar's last drawing is the output line")
    func progressBars() {
        let log = "[bloom] Running the setup script.\n###        22.4%\r######     96.3%\r########## 100.0%\n"
        #expect(progress("running", step: "setup", log: log)?.lastOutput == "########## 100.0%")
    }

    @Test("A failure marks its step, keeps what was done, and says what happened")
    func failure() {
        let failed = progress("failed", step: "setup", note: "composer install exited with 1")
        #expect(states(failed) == [.done, .done, .done, .failed, .todo])
        #expect(failed?.kind == .failed)
        #expect(failed?.failureNote == "composer install exited with 1")
        #expect(failed?.canRunAgain == true)
        #expect(failed?.opensLogAtFirst == true)
        #expect(failed?.title == "The setup script failed")
    }

    @Test("A failure with no step on the record is placed by the log's last step heading")
    func failureFromTheLog() {
        let log = "[bloom] Reading the team's environment.\n[bloom] Cloning the repository.\nfatal: repository not found\n"
        let failed = progress("failed", log: log)
        #expect(states(failed) == [.done, .done, .failed, .todo, .todo])
        #expect(failed?.failureNote == "fatal: repository not found")
        // A clone that failed left nothing to run setup in.
        #expect(failed?.canRunAgain == false)
        #expect(failed?.title == "Cloning failed")
    }

    @Test("A failure nothing can place marks nothing as done")
    func unplacedFailure() {
        let failed = progress("failed", log: "something went wrong\n")
        #expect(states(failed) == [.todo, .todo, .todo, .todo, .todo])
        #expect(failed?.title == "Setup failed")
    }

    @Test("A setup that needs a fresh machine cannot be run again, and its code is not shown")
    func needsFreshMachine() {
        let failed = progress(
            "failed", step: "setup", note: "Setup needs root it can no longer have (setup_needs_fresh_machine)",
            failureCode: "setup_needs_fresh_machine"
        )
        #expect(failed?.canRunAgain == false)
        #expect(failed?.failureNote == "Setup needs root it can no longer have")
    }
}

@Suite("When a new Cloud workspace's steps began and ended")
struct CloudSetupClockTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test("A step watched from its start to its end has a duration")
    func watched() {
        var clock = CloudSetupClock()
        clock.observe(.machine, at: start)
        clock.observe(.connect, at: start.addingTimeInterval(24))
        clock.observe(.clone, at: start.addingTimeInterval(25))
        #expect(clock.duration(of: .connect) == 1)
        #expect(clock.start(of: .clone) == start.addingTimeInterval(25))
    }

    /// Somebody who opens the workspace two minutes into its setup script is not told the script
    /// has been running for three seconds.
    @Test("A step already running when the window opened has no start of its own")
    func notWatched() {
        var clock = CloudSetupClock()
        clock.observe(.setup, at: start)
        #expect(clock.start(of: .setup) == nil)
        clock.observe(.setup, at: start.addingTimeInterval(5))
        #expect(clock.start(of: .setup) == nil)
        clock.observe(.services, at: start.addingTimeInterval(60))
        #expect(clock.duration(of: .setup) == nil)
        #expect(clock.start(of: .services) == start.addingTimeInterval(60))
    }

    @Test("An anchor stands in for a start that was not watched")
    func anchors() {
        var clock = CloudSetupClock()
        clock.observe(.machine, at: start.addingTimeInterval(10))
        clock.observe(.connect, at: start.addingTimeInterval(30))
        #expect(clock.duration(of: .machine) == nil)
        #expect(clock.duration(of: .machine, anchors: [.machine: start]) == 30)
    }
}

@Suite("Reading a setup heading back to its step")
struct CloudSetupStepHeadingTests {
    @Test("The machine's own headings, word for word, and nothing else")
    func headings() {
        #expect(CloudSetupStep.step(forHeading: "Running the prepare script.") == "prepare")
        #expect(CloudSetupStep.step(forHeading: "Reading the team's environment.") == "environment")
        #expect(CloudSetupStep.step(forHeading: "Starting the project's services.") == "services")
        #expect(CloudSetupStep.step(forHeading: "Setup ran as bloom-agent") == nil)
        #expect(CloudSetupStep.step(forHeading: nil) == nil)
    }
}

@Suite("The connection banner over a workspace being built")
struct CloudSetupBannerTests {
    /// "Creating the machine" is the card's first step, and the banner saying the same over it
    /// was one of the two sentences the recording of a first workspace drew twice.
    @Test("A machine that is not ready yet is the card's to say")
    func notReadyIsTheCards() {
        let phase = WorkspaceConnection.Phase.notReady(message: "Its machine is not ready yet.", retryAfter: 5)
        #expect(CloudConnectionBanner.of(phase, isBuilding: true) == nil)
        #expect(CloudConnectionBanner.of(phase) != nil)
        // Everything else the banner says is still said, card or not.
        #expect(CloudConnectionBanner.of(.asleep, isBuilding: true) != nil)
    }
}
