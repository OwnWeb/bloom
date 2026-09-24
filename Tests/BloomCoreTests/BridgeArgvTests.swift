import Foundation
import Testing
@testable import BloomCore

/// The two argv builders, which is where a registration either reaches the CLI or does not.
///
/// Kept apart from the config and override builders because this is the other half of the same
/// decision: what Bloom writes, and what Bloom then tells the CLI to read.
@Suite("BridgeArgv", .tags(.security))
struct BridgeArgvTests {
    private let session = Session(workspaceID: WorkspaceID("w"), model: "opus")

    @Test("Claude Code is pointed at the config file and never told to ignore the user's servers")
    func claudeArgv() throws {
        let arguments = AgentRunner.argv(
            session: session,
            resume: nil,
            mcpConfigPath: "/tmp/bridge/s.mcp.json"
        )
        let flag = try #require(arguments.firstIndex(of: "--mcp-config"))
        #expect(arguments[flag + 1] == "/tmp/bridge/s.mcp.json")
        // `--strict-mcp-config` would shut every MCP server the user configured out of their own
        // chat. `WorkspaceNamer` passes it deliberately, for a call that must see nothing; a chat
        // is the opposite case.
        #expect(!arguments.contains("--strict-mcp-config"))
    }

    @Test("no config, no flag")
    func claudeArgvWithoutABridge() {
        #expect(!AgentRunner.argv(session: session, resume: nil).contains("--mcp-config"))
    }

    @Test("Claude Code reads Bloom's bridge and the private Cloud connections")
    func claudeCloudMcpConfig() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let written = try CloudMcpConfiguration.writeClaude([
            CloudMcpConnection(name: "flare", url: "https://runbloom.app/api/mcp/flare", bearer: "private-grant")
        ], sessionID: session.id, directory: root.path)
        let path = try #require(written)
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o640)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = try JSONSerialization.jsonObject(with: data)
        let document = try #require(parsed as? [String: Any])
        let servers = try #require(document["mcpServers"] as? [String: [String: Any]])
        let flare = try #require(servers["flare"])
        #expect(flare["url"] as? String == "https://runbloom.app/api/mcp/flare")
        #expect((flare["headers"] as? [String: String])?["Authorization"] == "Bearer private-grant")

        let arguments = AgentRunner.argv(
            session: session, resume: nil, mcpConfigPath: "/tmp/bridge.mcp.json",
            additionalMcpConfigPath: path
        )
        let flag = try #require(arguments.firstIndex(of: "--mcp-config"))
        #expect(arguments[(flag + 1)...(flag + 2)] == ["/tmp/bridge.mcp.json", path])
        #expect(!arguments.contains("private-grant"))
        let cleared = try CloudMcpConfiguration.writeClaude([], sessionID: session.id, directory: root.path)
        #expect(cleared == nil)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("Codex is given the overrides after app-server and never --strict-config")
    func codexArgv() {
        let attachment = BridgeAttachment(
            shimPath: "/tmp/bloom-bridge",
            socketPath: "/tmp/s.sock",
            token: "t",
            role: .workspace
        )
        let launch = CodexClient.launch(CodexClient.Configuration(
            cwd: "/tmp/w",
            environment: [:],
            bridge: attachment
        ))
        #expect(launch.arguments.starts(with: ["app-server", "--listen", "stdio://"]))
        #expect(launch.arguments.contains("-c"))
        #expect(launch.arguments.contains { $0.hasPrefix("mcp_servers.\(BridgeRegistration.serverName).command=") })
        // The same trap under a different name: it makes Codex refuse to start on a user config
        // holding anything this build does not recognise.
        #expect(!launch.arguments.contains("--strict-config"))
    }

    @Test("no attachment, no overrides")
    func codexArgvWithoutABridge() {
        let launch = CodexClient.launch(CodexClient.Configuration(cwd: "/tmp/w", environment: [:]))
        #expect(launch.arguments == CodexClient.arguments)
    }

    @Test("Cloud Codex selects an authenticated provider at the local gateway")
    func codexCloudModelGateway() {
        let launch = CodexClient.launch(CodexClient.Configuration(
            cwd: "/tmp/w",
            environment: ["OPENAI_API_KEY": "local-gateway-token"],
            modelGatewayBaseURL: "http://127.0.0.1:49152/v1"
        ))
        #expect(launch.arguments.contains("model_provider=\"bloom_cloud_gateway\""))
        #expect(launch.arguments.contains("model_providers.bloom_cloud_gateway.base_url=\"http://127.0.0.1:49152/v1\""))
        #expect(launch.arguments.contains("model_providers.bloom_cloud_gateway.env_key=\"OPENAI_API_KEY\""))
        #expect(launch.arguments.contains("model_providers.bloom_cloud_gateway.wire_api=\"responses\""))
        #expect(launch.arguments.contains("model_providers.bloom_cloud_gateway.requires_openai_auth=false"))
        #expect(!launch.arguments.contains { $0.contains("local-gateway-token") })
        #expect(launch.environment["OPENAI_API_KEY"] == "local-gateway-token")
    }

    @Test("Codex keeps the Cloud proxy grant in its environment")
    func codexCloudMcpConfig() {
        let launch = CodexClient.launch(CodexClient.Configuration(
            cwd: "/tmp/w", environment: [:], cloudMcpConnections: [
                CloudMcpConnection(name: "there-there", url: "https://runbloom.app/api/mcp/there-there", bearer: "private-grant")
            ]
        ))
        #expect(launch.arguments.contains { $0.contains("mcp_servers.there-there.url=") })
        #expect(launch.arguments.contains { $0.contains("bearer_token_env_var") })
        #expect(!launch.arguments.contains { $0.contains("private-grant") })
        #expect(launch.environment["BLOOM_MCP_THERE_THERE_TOKEN"] == "private-grant")
    }

    @Test("Grok is launched as ACP stdio without attaching to the user's leader")
    func grokArgv() {
        let attachment = BridgeAttachment(
            shimPath: "/tmp/bloom-bridge",
            socketPath: "/tmp/s.sock",
            token: "t",
            role: .workspace
        )
        let launch = GrokClient.launch(GrokClient.Configuration(
            cwd: "/tmp/w",
            environment: [:],
            model: "grok-4.6",
            effort: "high"
        ))
        #expect(launch.arguments.contains("agent"))
        #expect(launch.arguments.contains("--no-leader"))
        #expect(launch.arguments.contains("stdio"))
        #expect(launch.arguments.contains("--model"))
        #expect(launch.arguments.contains("grok-4.6"))
        #expect(launch.environment["GROK_DISABLE_AUTOUPDATER"] == "1")
        let servers = BridgeRegistration.grokServers(attachment)
        #expect(servers.count == 1)
        #expect(servers[0]["name"]?.stringValue == BridgeRegistration.serverName)
        #expect(servers[0]["command"]?.stringValue == "/tmp/bloom-bridge")
    }

    @Test("no Grok attachment, no MCP servers")
    func grokArgvWithoutABridge() {
        #expect(BridgeRegistration.grokServers(nil).isEmpty)
    }
}
