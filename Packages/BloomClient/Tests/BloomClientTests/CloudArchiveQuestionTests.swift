import Testing
@testable import BloomClient

@Suite("Asking to archive a workspace by name")
struct CloudArchiveQuestionTests {
    @Test("A name with no punctuation gets a question mark")
    func theOrdinaryCase() {
        #expect(CloudArchiveConfirmation.question(archiving: "Queue retries") == "Archive Queue retries?")
    }

    /// "Archive What is in this project??" is what somebody actually read.
    @Test("A name that is already a question is not asked twice")
    func aNameThatEndsInItsOwnPunctuation() {
        #expect(CloudArchiveConfirmation.question(archiving: "What is in this project?")
            == "Archive What is in this project?")
        #expect(CloudArchiveConfirmation.question(archiving: "Fix it!") == "Archive Fix it!")
        #expect(CloudArchiveConfirmation.question(archiving: "Read the docs.") == "Archive Read the docs.")
    }

    @Test("And a name with space around it is tidied before either")
    func trimmedFirst() {
        #expect(CloudArchiveConfirmation.question(archiving: "  Queue retries  ") == "Archive Queue retries?")
    }
}
