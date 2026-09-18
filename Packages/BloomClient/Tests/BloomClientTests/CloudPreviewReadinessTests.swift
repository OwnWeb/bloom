import BloomProtocol
import Testing
@testable import BloomClient

@Suite("What the preview pane says when there is no app to show")
struct CloudPreviewReadinessTests {
    @Test("Setup still going says so, and offers nothing to press")
    func settingUpFillsInByItself() throws {
        for state in ["pending", "running"] {
            let readiness = CloudPreviewReadiness.of(setup: SetupRecord(state: state))
            guard case .waiting(let notice) = readiness else {
                Issue.record("\(state) should hold the page back")
                return
            }
            #expect(notice.message.contains("still setting up"))
            #expect(notice.invitesRetry == false)
        }
    }

    @Test("A setup that failed or was skipped says which, and both can be acted on")
    func aSetupThatWillNotFinishOnItsOwn() throws {
        let failed = CloudPreviewReadiness.of(setup: SetupRecord(state: "failed"))
        guard case .waiting(let failure) = failed else {
            Issue.record("A failed setup should hold the page back")
            return
        }
        #expect(failure.message.contains("Setup failed"))
        #expect(failure.invitesRetry)

        let skipped = CloudPreviewReadiness.of(setup: SetupRecord(state: "skipped"))
        guard case .waiting(let note) = skipped else {
            Issue.record("A skipped setup should hold the page back")
            return
        }
        #expect(note.message.contains("without running setup"))
        #expect(note.invitesRetry)
        #expect(note.message != failure.message)
    }

    @Test("A finished setup, an ignored failure and a machine that said nothing all load the page")
    func everythingElseServes() {
        #expect(CloudPreviewReadiness.of(setup: SetupRecord(state: "succeeded")) == .serving)
        #expect(CloudPreviewReadiness.of(setup: SetupRecord(state: "ignored")) == .serving)
        #expect(CloudPreviewReadiness.of(setup: nil) == .serving)
    }

    @Test("A gateway error is nothing serving; the app's own error page is not")
    func onlyTheGatewayStatusesCount() {
        #expect(CloudPreviewReadiness.isSilent(status: 502))
        #expect(CloudPreviewReadiness.isSilent(status: 503))
        #expect(CloudPreviewReadiness.isSilent(status: 504))
        // The two a developer must be left looking at, and a page that has not loaded yet.
        #expect(!CloudPreviewReadiness.isSilent(status: 500))
        #expect(!CloudPreviewReadiness.isSilent(status: 404))
        #expect(!CloudPreviewReadiness.isSilent(status: 200))
        #expect(!CloudPreviewReadiness.isSilent(status: nil))
    }

    @Test("The sentence for a machine that answered nothing names no port")
    func noPortUntilTheRunnerReleaseIsPinned() {
        let message = CloudPreviewReadiness.nothingAnswered.message
        #expect(!message.contains("3000"))
        #expect(!message.contains("port "))
        #expect(message.contains("Start the app in its terminal"))
    }
}
