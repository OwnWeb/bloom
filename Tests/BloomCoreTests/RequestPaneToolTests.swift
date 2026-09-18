import BloomProtocol
import Foundation
import Synchronization
import Testing
@testable import BloomCore

/// The tool an agent on a machine uses to ask for a pane it cannot open.
@Suite("Asking for a pane from a machine")
struct RequestPaneToolTests {
    private func call(url: String?, told: Int) async throws -> (result: BridgeToolResult, asked: [String?]) {
        let asked = Mutex([String?]())
        let tool = RequestPaneTool { requested, _, _ in
            asked.withLock { $0.append(requested) }
            return told
        }
        var arguments: [String: JSONValue] = [:]
        if let url { arguments["url"] = .string(url) }
        // A handler is handed a request whose params ARE the arguments; `BridgeDispatch.callTool`
        // unwraps them before it gets here.
        let request = MCPRequest(id: .number(1), method: RequestPaneTool.name, params: .object(arguments))
        let identity = BridgeIdentity(sessionID: SessionID("01k5bx7j9d3v2r8q6m4n0p1s2w"),
                                      workspaceID: WorkspaceID("01k5bx7j9d3v2r8q6m4n0p1s2x"), role: .workspace)
        let result = await tool.call(request, as: identity, store: try makeTestStore("request-pane"))
        return (result, asked.withLock { $0 })
    }

    /// The case the whole tool was nearly not built for: a machine runs with every window shut, and
    /// an agent told it had succeeded would go on to say so to somebody who saw nothing.
    @Test("nobody looking is said plainly and is not an error")
    func nobodyIsLooking() async throws {
        let (result, _) = try await call(url: nil, told: 0)

        #expect(result.text.contains("nobody to ask"))
        #expect(result.text.contains("Nothing was opened"))
        // Not a failure: the agent did nothing wrong and there is nothing to retry.
        #expect(!result.isError)
    }

    @Test("a client listening is told, and the answer refuses to call it done")
    func someoneIsLooking() async throws {
        let (result, asked) = try await call(url: "https://example.test/dashboard", told: 2)

        #expect(result.text.contains("Asked 2 clients"))
        #expect(result.text.contains("https://example.test/dashboard"))
        #expect(result.text.contains("do not report it as done"))
        #expect(asked == ["https://example.test/dashboard"])
    }

    /// No url means the workspace's own public address, which a client connected to it already has,
    /// so the machine does not have to know its own name to answer.
    @Test("no url asks for the workspace's own address")
    func defaultsToTheWorkspace() async throws {
        let (result, asked) = try await call(url: nil, told: 1)

        #expect(asked == [String?.none])
        #expect(result.text.contains("public address"))
        #expect(result.text.contains("Asked 1 client"))
    }

    /// A pane is a browser, and `file:` or `javascript:` in one is a way to read the machine
    /// through a window somebody trusted. Refused here as `BrowserPaneTool` refuses them on the Mac.
    @Test("only http and https can be asked for")
    func refusesOtherSchemes() async throws {
        for scheme in ["file:///etc/passwd", "javascript:alert(1)", "bloom://workspace/1"] {
            let (result, asked) = try await call(url: scheme, told: 3)
            #expect(result.isError, "\(scheme) should be refused")
            #expect(asked.isEmpty, "nothing should reach a client for \(scheme)")
        }
    }
}
