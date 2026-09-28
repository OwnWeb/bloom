import Testing
@testable import BloomCore

/// What a tool is called, once a reader is looking at it.
///
/// The naming was private to `ToolPresenter.mcp` and the streaming tail could not reach it, so a
/// running MCP call said `mcp__bloom-workspace-bridge__workspace_say` for as long as it ran and
/// "Bloom: workspace say" from the moment it finished. The point of the type is that both now ask
/// one thing, and the point of this suite is that the one thing still answers what the rows were
/// already asserting in `CrewPresentationTests` and `PaneToolTests`.
@Suite("An MCP tool's name, as a reader meets it")
struct MCPToolNameTests {
    @Test("a server and a tool become a sentence")
    func serverAndToolReadAsEnglish() {
        let name = MCPToolName("mcp__linear__create_issue")

        #expect(name?.server == "linear")
        #expect(name?.bare == "create_issue")
        #expect(name?.tool == "create issue")
        #expect(name?.label == "linear: create issue")
    }

    /// The wire name is a name nobody would type, for the reason on `BridgeRegistration.serverName`.
    /// Nothing about that belongs on screen.
    @Test("Bloom's own bridge is said as Bloom")
    func theBridgeIsSaidAsBloom() {
        let name = MCPToolName("mcp__\(BridgeRegistration.serverName)__workspace_say")

        #expect(name?.isBloom == true)
        #expect(name?.label == "Bloom: workspace say")
    }

    /// The double underscore separates the segments and a single one inside a segment is a word
    /// break, which is why `bare` and `tool` are two strings rather than one.
    @Test("a tool with its own double underscore keeps it for a lookup and loses it for a reader")
    func aNestedSeparatorIsBothThings() {
        let name = MCPToolName("mcp__acme__deep__nested_call")

        #expect(name?.bare == "deep__nested_call")
        #expect(name?.tool == "deep nested call")
    }

    @Test("a server with no tool is the server alone")
    func aServerAloneIsTheLabel() {
        #expect(MCPToolName("mcp__linear")?.label == "linear")
    }

    @Test("a built-in tool is not an MCP call")
    func aBuiltInIsNotParsed() {
        #expect(MCPToolName("Bash") == nil)
        #expect(MCPToolName("WebFetch") == nil)
    }

    // MARK: - What the running line says

    @Test("a running MCP call reads as the row it is about to become")
    func theTailMatchesTheSavedRow() {
        let wire = "mcp__\(BridgeRegistration.serverName)__workspace_say"

        #expect(MCPToolName.readable(wire) == "Bloom: workspace say")
        #expect(MCPToolName.readable("mcp__linear__create_issue") == "linear: create issue")
    }

    /// A built-in is already a word, and the tail has always said it correctly. Nothing here may
    /// change that.
    @Test("a built-in is left exactly as it arrived")
    func aBuiltInIsUntouched() {
        #expect(MCPToolName.readable("Bash") == "Bash")
        #expect(MCPToolName.readable("TodoWrite") == "TodoWrite")
    }
}
