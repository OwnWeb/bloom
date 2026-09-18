import Testing
@testable import BloomCore

@Suite("Telling the machine's own words from a script's output")
struct SetupLogVoiceTests {
    @Test("The marker says whose line it is and never appears in what a person reads")
    func theMarkerPicksTheInkAndGoes() {
        #expect(SetupLogVoice.isBloom("[bloom] Cloning the repository."))
        #expect(!SetupLogVoice.isBloom("Cloning into 'bloom'..."))
        #expect(SetupLogVoice.spoken("[bloom] Cloning the repository.") == "Cloning the repository.")
        // A script's output is never rewritten, whatever is in it.
        #expect(SetupLogVoice.spoken("  [bloom] not at the start") == "  [bloom] not at the start")
    }

    @Test("The newest thing the machine said is what goes under the row")
    func theNewestNoteIsTheMachines() {
        let log = """
        [bloom] Cloning the repository.
        Cloning into 'bloom'...
        [bloom] Running the project's setup.
        composer install
        [bloom] Setup has been in running the project's setup for 6 minutes with nothing new.
        """
        #expect(SetupLogVoice.newestNote(in: log) ==
            "Setup has been in running the project's setup for 6 minutes with nothing new.")
        // A script's last line is not a sentence anybody wrote for a reader.
        #expect(SetupLogVoice.newestNote(in: "composer install\nnothing to install") == nil)
        #expect(SetupLogVoice.newestNote(in: "") == nil)
    }

    /// A step heading is a `[bloom]` line too, and the row is already showing it as its one line.
    @Test("The step's own heading is not repeated under the row")
    func theHeadingIsNotSaidTwice() {
        let log = "[bloom] Configuring git."
        #expect(SetupLogVoice.newestNote(in: log, excluding: "Configuring git") == nil)
        #expect(SetupLogVoice.newestNote(in: log, excluding: "configuring git.") == nil)
        #expect(SetupLogVoice.newestNote(in: log, excluding: "Cloning the repository") == "Configuring git.")
    }
}
