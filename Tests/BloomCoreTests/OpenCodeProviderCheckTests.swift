import Testing
import Foundation
@testable import BloomCore

struct OpenCodeProviderCheckTests {
    @Test("only OpenCode's measured no-model error means no provider")
    func verdictReadsOnlyTheMeasuredError() {
        let none = ACPRPCError(
            code: -32603,
            message: "Internal error: No models are available",
            data: .object(["errorName": .string("CatalogNotReady")])
        )
        #expect(OpenCodeProviderCheck.verdict(for: none) == false)
        #expect(OpenCodeProviderCheck.verdict(for: ACPRPCError(code: -32603, message: "Internal error")) == nil)
        #expect(OpenCodeProviderCheck.verdict(for: ACPClientError.connectionClosed("gone")) == nil)
    }

    @Test("no provider shows OpenCode as installed, and an unknown answer as connected")
    func detailsFollowTheVerdict() {
        #expect(AgentCatalog.openCodeDetails(version: "2.3.2", hasProvider: false).isEmpty)
        #expect(!AgentCatalog.openCodeDetails(version: "2.3.2", hasProvider: nil).isEmpty)
        #expect(!AgentCatalog.openCodeDetails(version: "2.3.2", hasProvider: true).isEmpty)
    }

    @Test("a session that opens is a provider, and the session is deleted")
    func openedSessionIsAProvider() async {
        let box = ProcessBox()
        box.reply(to: "initialize", with: .object([:]))
        var created = OpenCodeFixture.configOptions(model: OpenCodeFixture.localModel).objectValue ?? [:]
        created["sessionId"] = .string("ses_check")
        box.reply(to: "session/new", with: .object(created))

        let found = await OpenCodeProviderCheck.hasProvider(executable: "opencode", cwd: "/tmp") { configuration in
            OpenCodeClient(configuration: configuration, makeProcess: box.factory)
        }
        #expect(found == true)
        #expect(box.process.sentMethods.contains("session/delete"))
    }
}
