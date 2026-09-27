import Testing
@testable import BloomCore

@Suite("Provider credentials in process environments")
struct ProviderCredentialEnvironmentTests {
    @Test("untrusted processes lose every provider credential alias and keep ordinary variables")
    func untrustedProcessesAreScrubbed() {
        var environment = ["BLOOM_ALLOWED": "kept"]
        for name in ProviderCredentialEnvironment.prohibitedNames {
            environment[name.lowercased()] = "sentinel-\(name)"
        }

        let scrubbed = ProviderCredentialEnvironment.untrustedProcess(environment)

        #expect(scrubbed == ["BLOOM_ALLOWED": "kept"])
    }

    @Test("each explicit agent boundary receives only its selected local gateway credential",
          arguments: AgentKind.allCases)
    func agentBoundary(agent: AgentKind) {
        var inherited = ["PATH": "/usr/bin", "BLOOM_ALLOWED": "inherited"]
        for name in ProviderCredentialEnvironment.prohibitedNames {
            inherited[name] = "inherited-sentinel"
        }
        let canonical = switch agent {
        case .claudeCode, .cursor, .openCode: "ANTHROPIC_API_KEY"
        case .codex: "OPENAI_API_KEY"
        case .grok: "XAI_API_KEY"
        }
        let granted = [canonical: "selected-sentinel", "TURN_ALLOWED": "granted"]

        let result = ProviderCredentialEnvironment.agent(
            agent, granted: granted, inheriting: inherited
        )
        let providerValues = result.filter {
            ProviderCredentialEnvironment.prohibitedNames.contains($0.key.uppercased())
        }

        #expect(providerValues.count == 1)
        #expect(providerValues.first?.value == "selected-sentinel")
        #expect(result["PATH"] == "/usr/bin")
        #expect(result["BLOOM_ALLOWED"] == "inherited")
        #expect(result["TURN_ALLOWED"] == "granted")
        #expect(!result.values.contains("inherited-sentinel"))
    }

    @Test("an exact subprocess environment does not merge Bloom's inherited variables")
    func exactSubprocessEnvironment() async throws {
        let result = try await Shell.run(
            "/usr/bin/env", environment: ["BLOOM_ALLOWED": "kept"]
        )

        #expect(result.ok)
        #expect(result.stdout.contains("BLOOM_ALLOWED=kept"))
        #expect(!result.stdout.contains("PATH="))
        for name in ProviderCredentialEnvironment.prohibitedNames {
            #expect(!result.stdout.uppercased().contains(name + "="))
        }
    }
}
