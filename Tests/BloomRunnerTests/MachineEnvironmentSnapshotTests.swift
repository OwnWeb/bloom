import Foundation
import Testing
@testable import BloomRunner

struct MachineEnvironmentSnapshotTests {
    @Test("provider credentials stay outside setup and service scopes")
    func providerCredentialsStayOut() async throws {
        let environment = MachineEnvironment(
            fetchVariables: {
                try MachineEnvironmentResponse(variables: ["ORDINARY": "value", "OPENAI_API_KEY": "broad-provider"])
            },
            fetchSecrets: { _ in ["SERVICE_TOKEN": "scoped", "ANTHROPIC_API_KEY": "scoped-provider"] }
        )
        let variables = try await environment.requiredRefresh()
        let scoped = try await environment.scoped(.setup(attemptID: UUID()), base: variables)
        #expect(scoped.values == ["ORDINARY": "value", "SERVICE_TOKEN": "scoped"])
        #expect(scoped.redactions == ["scoped"])
    }

    @Test("ordinary environment is versioned and closed")
    func ordinaryEnvironment() throws {
        let value = try JSONDecoder().decode(
            MachineEnvironmentResponse.self,
            from: Data(#"{"version":1,"variables":{"APP_ENV":"testing"}}"#.utf8)
        )
        #expect(value.variables == ["APP_ENV": "testing"])
    }

    @Test("ordinary environment rejects secrets, unknown fields, versions and names", arguments: [
        #"{"version":1,"variables":{},"secrets":[]}"#,
        #"{"version":2,"variables":{}}"#,
        #"{"version":1,"variables":{"BAD-NAME":"x"}}"#,
    ])
    func rejectsUnsafeEnvironment(json: String) {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MachineEnvironmentResponse.self, from: Data(json.utf8))
        }
    }

    @Test("a handoff id in lower case is a ULID too")
    func lowerCaseHandoffIdentifiers() throws {
        // **This is the id runbloom.app actually sends**, and requiring upper case refused every
        // one of them: a workspace cloned, installed its packages, and then would not run the
        // repository's own setup script, saying only that it could not obtain the setup secrets.
        // Crockford's base32 is case insensitive and the server writes its ULIDs in lower case.
        let issued = try JSONDecoder().decode(
            SecretHandoff.self,
            from: Data(#"{"version":1,"handoff_id":"01m34ynxf6rq110ga3fhaq9sj0","expires_at":"2099-01-01T00:00:00Z"}"#.utf8)
        )
        #expect(issued.id == "01m34ynxf6rq110ga3fhaq9sj0", "the id is passed on as it was sent")

        // Mixed case is still a ULID, and something that is not base32 still is not.
        #expect(throws: Never.self) {
            try JSONDecoder().decode(
                SecretHandoff.self,
                from: Data(#"{"version":1,"handoff_id":"01M34ynxF6rq110GA3fhaq9SJ0","expires_at":"2099-01-01T00:00:00Z"}"#.utf8)
            )
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                SecretHandoff.self,
                from: Data(#"{"version":1,"handoff_id":"01m34ynxf6rq110ga3fhaq9si0","expires_at":"2099-01-01T00:00:00Z"}"#.utf8)
            )
        }
    }

    @Test("handoff responses are closed and hide values from descriptions")
    func handoffResponses() throws {
        let issue = try JSONDecoder().decode(
            SecretHandoff.self,
            from: Data(#"{"version":1,"handoff_id":"01ARZ3NDEKTSV4RRFFQ69G5FAV","expires_at":"2099-01-01T00:00:00Z"}"#.utf8)
        )
        let consumption = try JSONDecoder().decode(
            SecretHandoffConsumption.self,
            from: Data(#"{"version":1,"secrets":{"TOKEN":"sentinel-secret"}}"#.utf8)
        )
        #expect(issue.id == "01ARZ3NDEKTSV4RRFFQ69G5FAV")
        #expect(consumption.secrets["TOKEN"] == "sentinel-secret")
        #expect(!String(reflecting: issue).contains(issue.id))
        #expect(!String(describing: consumption).contains("sentinel-secret"))
        #expect(!String(reflecting: consumption).contains("sentinel-secret"))
    }

    @Test("handoff responses reject extra fields and malformed values", arguments: [
        #"{"version":1,"handoff_id":"bad","expires_at":"2099-01-01T00:00:00Z"}"#,
        #"{"version":1,"handoff_id":"01ARZ3NDEKTSV4RRFFQ69G5FAV","expires_at":"2099-01-01T00:00:00Z","secrets":{}}"#,
    ])
    func rejectsUnsafeIssue(json: String) {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(SecretHandoff.self, from: Data(json.utf8))
        }
    }
}
