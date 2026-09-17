import Foundation

/// What one agent process needs to reach the bridge, once Bloom has minted its identity.
///
/// Two fields because the two CLIs are told about an MCP server in completely different ways and
/// neither can be made to look like the other. Claude Code reads a JSON file named by
/// `--mcp-config`; Codex takes `-c mcp_servers.<name>.…` overrides carrying the same values
/// inline. The token and the socket are the same on both sides, which is why they live in the
/// attachment rather than being built twice.
public struct BridgeHandle: Sendable, Hashable {
    public let attachment: BridgeAttachment
    /// The mode 0600 config file. CLI shims reread it after app restarts; regular Codex and Grok
    /// chats register without a file.
    public let mcpConfigPath: String?

    public init(attachment: BridgeAttachment, mcpConfigPath: String?) {
        self.attachment = attachment
        self.mcpConfigPath = mcpConfigPath
    }
}
