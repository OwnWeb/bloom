import Foundation
import Testing
@testable import BloomCore

/// `cloud_workspace_start`: an agent asking for a Bloom Cloud workspace.
///
/// The window's half is a stub, as it is in `WorkspaceStartToolTests`, because what the app does
/// with an order needs an account and runbloom.app. Which project the order lands in is
/// `CloudProjectChoice`, tested in BloomClient. What this pins is every refusal the tool makes
/// before anything is spent, and that the order it hands over is the one that was asked for.
@Suite("cloud_workspace_start", .tags(.persistence), .scratchDirectory)
struct MacCloudWorkspaceStartToolTests {
    private final class Recorder: @unchecked Sendable {
        var orders: [MacCloudWorkspaceOrder] = []
        var allowed = true
        var answer: CloudWorkspaceAnswer = .created(
            CloudWorkspaceCreated(id: "cw-1", name: "Port the importer", state: "setting_up", url: "https://runbloom.app/w/cw-1")
        )

        func tool() -> MacCloudWorkspaceStartTool {
            MacCloudWorkspaceStartTool(
                allowed: { [self] in allowed },
                start: { [self] order in
                    orders.append(order)
                    return answer
                },
                repositoryOf: { path in path == "/tmp/flare" ? "spatie/flare" : nil }
            )
        }
    }

    private func fixture(origin: WorkspaceOrigin = .user, label: String) async throws -> (Store, BridgeIdentity) {
        let store = try makeTestStore(label)
        let repo = try await store.upsert(Repo(name: "flare", path: "/tmp/flare", defaultBranch: "main"))
        let workspace = try await store.upsert(Workspace(
            repoID: repo.id, name: "group occurrences", branch: "claude/group-occurrences",
            path: "/tmp/flare-group", baseBranch: "main", origin: origin
        ))
        let session = try await store.upsert(Session(workspaceID: workspace.id, title: "First chat"))
        return (store, BridgeIdentity(sessionID: session.id, workspaceID: workspace.id, role: .workspace))
    }

    private func request(_ arguments: [String: JSONValue]) -> MCPRequest {
        MCPRequest(id: .number(1), method: "cloud_workspace_start", params: .object(arguments))
    }

    @Test("every workspace agent and the owner see it")
    func roles() {
        let tool = Recorder().tool()
        #expect(tool.roles == [.workspace, .owner])
        #expect(tool.tool.description.contains("costs real money"))
        #expect(tool.tool.inputSchema["properties"]?["effort"] != nil)
    }

    /// It spends money, so Bloom never answers its ask itself, the argument that keeps
    /// `workspace_archive` off the list too. Whether the CLI then asks the owner is the chat's
    /// permission mode, which is why Bloom asks as well: see `CloudWorkspaceStartQuestion`.
    @Test("Bloom never answers its permission ask itself")
    func notSelfApproved() {
        #expect(!BridgeToolApproval.isSelfApproved(toolName: "\(BridgeToolApproval.toolPrefix)cloud_workspace_start"))
    }

    @Test("off, it refuses with the sentence naming the setting, and nothing is created")
    func offByDefault() async throws {
        let (store, identity) = try await fixture(label: "cloud-off")
        let recorder = Recorder()
        recorder.allowed = false

        let result = await recorder.tool().call(request(["name": .string("Do it")]), as: identity, store: store)

        #expect(result.isError)
        #expect(result.text == MacCloudWorkspaceStartTool.offSentence)
        #expect(result.text.contains(MacCloudWorkspaceStartTool.settingTitle))
        #expect(result.text.contains("costs money"))
        #expect(recorder.orders.isEmpty)
    }

    @Test("a workspace an agent started may not make machines either")
    func noGrandchildren() async throws {
        let (store, identity) = try await fixture(
            origin: .agent(parentWorkspaceID: WorkspaceID(rawValue: "w-parent"), spawnToolUseID: "t1"),
            label: "cloud-child"
        )
        let recorder = Recorder()

        let result = await recorder.tool().call(request(["name": .string("Do it")]), as: identity, store: store)

        #expect(result.isError)
        #expect(result.text.contains("itself started by an agent"))
        #expect(recorder.orders.isEmpty)
    }

    @Test("a missing name is refused, and so is a run_setup that is not a boolean")
    func needsSomething() async throws {
        let (store, identity) = try await fixture(label: "cloud-empty")
        let recorder = Recorder()

        let empty = await recorder.tool().call(request(["prompt": .string("  ")]), as: identity, store: store)
        #expect(empty.isError)
        #expect(empty.text.contains("Give the new workspace a name"))

        let setup = await recorder.tool().call(
            request(["name": .string("Empty"), "run_setup": .string("no")]), as: identity, store: store
        )
        #expect(setup.isError)
        #expect(recorder.orders.isEmpty)
    }

    @Test("the order is what was asked, with the caller's repository beside it")
    func order() async throws {
        let (store, identity) = try await fixture(label: "cloud-order")
        let recorder = Recorder()
        let sessionID = try #require(identity.sessionID)
        try await store.setSetting(ComposerControls.fastModeKey(sessionID: sessionID), "1")
        try await store.setSetting(ComposerControls.outputStyleKey(sessionID: sessionID), "Concise")

        let result = await recorder.tool().call(request([
            "name": .string(" Port the importer "), "prompt": .string(" Move it "),
            "branch": .string("freekmurze/importer"),
            "base_branch": .string("develop"), "run_setup": .bool(false),
            "effort": .string("medium"),
        ]), as: identity, store: store)

        #expect(!result.isError)
        let order = try #require(recorder.orders.first)
        #expect(order.order == CloudWorkspaceOrder(
            name: "Port the importer",
            branch: "freekmurze/importer",
            baseBranch: "develop",
            runSetup: false,
            prompt: "Move it",
            effort: "medium"
        ))
        #expect(order.callerControls?.model == AppDefaults.fallbackModel)
        #expect(order.callerControls?.effort == AppDefaults.fallbackEffort)
        #expect(order.callerControls?.isFastMode == true)
        #expect(order.callerControls?.outputStyle == "Concise")
        #expect(order.callerRepository == "spatie/flare")
        #expect(order.requestedBy == "\u{201C}group occurrences\u{201D}")
        #expect(result.text.contains("\"cw-1\""))
        #expect(result.text.contains("setting_up"))
    }

    @Test("run_setup left out is true, and the owner's client has no repository of its own")
    func ownerDefaults() async throws {
        let (store, _) = try await fixture(label: "cloud-owner")
        let recorder = Recorder()

        _ = await recorder.tool().call(
            request(["name": .string("Empty"), "project": .string("p1")]),
            as: .owner, store: store
        )

        #expect(recorder.orders == [MacCloudWorkspaceOrder(
            order: CloudWorkspaceOrder(name: "Empty", project: "p1")
        )])
    }

    @Test("a prompt from a missing chat is refused rather than handed fallback controls")
    func missingChatIsRefused() async throws {
        let (store, identity) = try await fixture(label: "cloud-missing-chat")
        let recorder = Recorder()
        let workspaceID = try #require(identity.workspaceID)
        let missing = BridgeIdentity(
            sessionID: SessionID("missing"),
            workspaceID: workspaceID,
            role: .workspace
        )

        let result = await recorder.tool().call(
            request(["name": .string("Do it"), "prompt": .string("Fix it")]),
            as: missing,
            store: store
        )

        #expect(result.isError)
        #expect(result.text.contains("no longer open"))
        #expect(recorder.orders.isEmpty)
    }

    /// On unless turned off, because each one costs money; and when it is asked, it says who asked,
    /// what would be made where, and that it costs money.
    @Test("Bloom's own question is on by default and names what would be created")
    func question() {
        #expect(CloudWorkspaceStartQuestion.asks(stored: nil))
        #expect(CloudWorkspaceStartQuestion.asks(stored: true))
        #expect(!CloudWorkspaceStartQuestion.asks(stored: false))

        let question = CloudWorkspaceStartQuestion(
            requestedBy: "\u{201C}group occurrences\u{201D}", name: "Port the importer", project: "spatie/flare",
            branch: "freekmurze/port-the-importer", baseBranch: "main", runSetup: false
        )
        #expect(question.message.hasPrefix("An agent in \u{201C}group occurrences\u{201D} wants to create"))
        #expect(question.message.contains("spatie/flare"))
        #expect(question.message.contains("freekmurze/port-the-importer from main"))
        #expect(question.message.contains("costs money"))
        #expect(question.message.contains("skips the project's setup"))

        let fromOwner = CloudWorkspaceStartQuestion(
            requestedBy: nil, name: "Empty", project: "spatie/flare", branch: "b", baseBranch: "main", runSetup: true
        )
        #expect(fromOwner.message.hasPrefix("An agent wants to create"))
        #expect(!fromOwner.message.contains("setup"))
    }

    @Test("the window's refusal is passed on as it was said")
    func refusalPassedOn() async throws {
        let (store, identity) = try await fixture(label: "cloud-refused")
        let recorder = Recorder()
        recorder.answer = .refused("No Bloom Cloud project is spatie/flare.")

        let result = await recorder.tool().call(
            request(["name": .string("Do it"), "prompt": .string("do it")]), as: identity, store: store
        )

        #expect(result.isError)
        #expect(result.text == "No Bloom Cloud project is spatie/flare.")
    }
}
