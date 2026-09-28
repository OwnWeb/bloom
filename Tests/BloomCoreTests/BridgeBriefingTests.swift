import Foundation
import Testing
@testable import BloomCore

@Suite("Bridge initialization instructions")
struct BridgeBriefingTests {
    @Test("the tool list comes from the toolbox")
    func toolsComeFromTheToolbox() {
        let sentence = BridgeBriefing.tools(["whoami", "chat_read", "agent_start"])
        #expect(sentence.contains("agent_start, chat_read, whoami"))
        #expect(BridgeBriefing.tools([]).isEmpty)
    }

    @Test("a toolbox with a briefing sends it as MCP instructions")
    func initializeCarriesIt() async throws {
        let store = try makeTestStore("bridge-briefing")
        let toolbox = BridgeToolbox(handlers: [WhoamiTool()], briefing: "Local workspace.")
        let dispatch = BridgeDispatch(store: store, identity: .owner, toolbox: toolbox)
        let reply = try #require(await dispatch.respond(to: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#))
        #expect(reply.contains("instructions"))
        #expect(reply.contains("whoami"))

        let quiet = BridgeDispatch(store: store, identity: .owner, toolbox: BridgeToolbox(handlers: [WhoamiTool()]))
        let plain = try #require(await quiet.respond(to: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#))
        #expect(!plain.contains("instructions"))
    }
}
