import Foundation
import Testing
@testable import BloomClient

@Suite("Project icon failure retries")
struct ProjectIconFailurePolicyTests {
    @Test("network, timeout, throttle and server failures retry")
    func transientFailures() {
        #expect(ProjectIconFailurePolicy.shouldRetry(URLError(.networkConnectionLost)))
        #expect(ProjectIconFailurePolicy.shouldRetry(RunbloomRefusal(status: 408, code: "timeout", message: "")))
        #expect(ProjectIconFailurePolicy.shouldRetry(RunbloomRefusal(
            status: 429, code: "too_many_requests", message: "", retryAfter: 5
        )))
        #expect(ProjectIconFailurePolicy.shouldRetry(RunbloomRefusal(status: 503, code: "server_error", message: "")))
    }

    @Test("authorisation, absence, unsafe endpoints and broken images stay on initials")
    func permanentFailures() {
        #expect(!ProjectIconFailurePolicy.shouldRetry(RunbloomRefusal(status: 403, code: "forbidden", message: "")))
        #expect(!ProjectIconFailurePolicy.shouldRetry(RunbloomRefusal(status: 404, code: "not_found", message: "")))
        #expect(!ProjectIconFailurePolicy.shouldRetry(RunbloomRefusal(status: 0, code: "unsafe_endpoint", message: "")))
        #expect(!ProjectIconFailurePolicy.shouldRetry(RunbloomRefusal(
            status: 200, code: "unreadable_project_icon", message: ""
        )))
    }
}
