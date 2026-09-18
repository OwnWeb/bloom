import Testing
@testable import BloomClient

@Suite("What a machine's setup step is called")
struct CloudSetupStepTests {
    /// The machine's own headings, from `SetupLog.title` on the runner, verbatim.
    ///
    /// **The suppression that keeps a row from saying the same thing twice rests on these.** The
    /// machine writes one `[bloom] ` line per step, and the row draws the newest `[bloom] ` line
    /// as its note unless that line is the step's own heading, which it recognises by comparing
    /// what it would have written itself. So the client's long form has to BE the machine's
    /// sentence, and where it was not, the row said "Running the setup script." under a line
    /// already reading "Running the project's setup".
    ///
    /// Pinned rather than trusted: this is a contract between two repositories' worth of code
    /// that nothing else checks, and the cost of it drifting is paid by whoever is watching the
    /// two slowest steps of a setup.
    private static let headings = [
        "environment": "Reading the team's environment.",
        "git": "Configuring git.",
        "clone": "Cloning the repository.",
        "prepare": "Running the prepare script.",
        "setup": "Running the setup script.",
        "resume": "Running the resume script.",
        "services": "Starting the project's services.",
    ]

    @Test("Every step is said in the machine's own words")
    func theLongFormIsTheMachinesHeading() throws {
        for (step, heading) in Self.headings {
            let said = try #require(CloudSetupStep.sentence(step))
            #expect(said.prefix(1).uppercased() + said.dropFirst() + "." == heading)
        }
    }

    @Test("The short form is for a subtitle that already carries the heading")
    func theShortFormIsShorter() throws {
        #expect(CloudSetupStep.short("clone") == "cloning")
        #expect(CloudSetupStep.short("services") == "starting services")
        for step in Self.headings.keys {
            let short = try #require(CloudSetupStep.short(step))
            let long = try #require(CloudSetupStep.sentence(step))
            #expect(short.count <= long.count)
        }
    }

    /// A newer runner naming a step this version has never seen is still telling somebody what it
    /// is doing, and the raw word is nearly always readable. Silence is the one answer that is
    /// certainly wrong, and it is what one of the two tables used to give.
    @Test("An unknown step is said as it stands, in both registers")
    func anUnknownStepSurvives() {
        #expect(CloudSetupStep.sentence("seeding") == "seeding")
        #expect(CloudSetupStep.short("seeding") == "seeding")
        #expect(CloudSetupStep.sentence(nil) == nil)
        #expect(CloudSetupStep.short("") == nil)
    }
}
