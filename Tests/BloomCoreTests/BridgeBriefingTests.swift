import Foundation
import Testing
@testable import BloomCore

/// The facts an agent on a machine had to work out by exhaustion, now told to it.
@Suite("What an agent is told about a Cloud machine")
struct BridgeBriefingTests {
    static let briefing = BridgeBriefing.machine(
        publicURL: "https://bloom-01m2t31b.sprites.app", appPort: 3000,
        reservedPorts: [(8080, "the preview proxy"), (8081, "Bloom Runner itself")]
    )

    /// Each of these cost an agent several actions to discover on 18 September 2026.
    @Test("it says where a page is shown, which ports are taken, and that panes are somewhere else")
    func saysTheExpensiveFacts() {
        #expect(Self.briefing.contains("https://bloom-01m2t31b.sprites.app"))
        #expect(Self.briefing.contains("BLOOM_APP_PORT"))
        #expect(Self.briefing.contains("8081"))
        #expect(Self.briefing.contains("http = true"))
        // The one that turned a question into thirty-five actions: absence as an answer.
        #expect(Self.briefing.contains("belong to whoever is looking"))
        #expect(Self.briefing.contains("absence of a tool for it is the answer"))
    }

    /// Generated rather than written, so a tool added or removed cannot leave the sentence lying.
    @Test("the tool list is the toolbox's own")
    func toolsComeFromTheToolbox() {
        let sentence = BridgeBriefing.tools(["whoami", "chat_read", "agent_start"])

        #expect(sentence.contains("agent_start, chat_read, whoami"))
        #expect(BridgeBriefing.tools([]).isEmpty)
    }

    /// The channel that needs no tool call, so an agent reads it before it can go looking.
    @Test("a toolbox with a briefing sends it as MCP instructions")
    func initializeCarriesIt() async throws {
        let store = try makeTestStore("bridge-briefing")
        let toolbox = BridgeToolbox(handlers: [WhoamiTool()], briefing: Self.briefing)
        let dispatch = BridgeDispatch(store: store, identity: .owner, toolbox: toolbox)

        let reply = try #require(await dispatch.respond(to: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#))
        #expect(reply.contains("instructions"))
        #expect(reply.contains("whoami"))

        // And nothing is said where there is nothing to say: on the owner's Mac the agent is
        // already in the place it can see.
        let quiet = BridgeDispatch(store: store, identity: .owner, toolbox: BridgeToolbox(handlers: [WhoamiTool()]))
        let plain = try #require(await quiet.respond(to: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#))
        #expect(!plain.contains("instructions"))
    }
}
