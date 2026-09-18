import Foundation

/// `cloud_setup`: what an agent needs before it writes or fixes the scripts and services that make a
/// project work on a Cloud workspace.
///
/// **A tool rather than more briefing**, because the briefing is read by every agent on every
/// connection and this is read by the one agent that is about to touch `.bloom/settings.toml`. The
/// briefing names it, which is how it is found; `BridgeBriefing.tools` generates that list from the
/// toolbox, so it cannot go missing.
///
/// **Offered on a Mac as well as on a machine**, and that is the point rather than a convenience: a
/// project can be perfectly happy locally and collide on its first machine, and the cheapest moment
/// to get all of this right is before the first machine exists.
public struct CloudSetupTool: BridgeToolHandling {
    public init() {}

    public let roles: Set<BridgeRole> = [.workspace, .owner]

    public static let name = "cloud_setup"

    public let tool = BridgeTool(
        name: CloudSetupTool.name,
        description: """
            How a project is made to work on a Bloom Cloud workspace: what runs and when, which ports are \
            taken, what belongs in a service rather than in a script, what the environment holds, \
            and how to check it rather than guess.

            Read this before writing or changing .bloom/settings.toml, before adding a setup or \
            resume script, and when a Bloom Cloud workspace's setup fails or its preview is blank. It is \
            the same guidance on a Mac, where getting it right costs nothing, and on a machine, \
            where getting it wrong has already cost somebody an afternoon.

            Takes no arguments. Read only.
            """,
        inputSchema: BridgeTool.noArguments
    )

    public func call(
        _ request: MCPRequest,
        as identity: BridgeIdentity,
        store: Store
    ) async -> BridgeToolResult {
        .init(text: CloudSetupGuide.text)
    }
}
