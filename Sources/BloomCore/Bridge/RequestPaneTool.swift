import Foundation

/// `request_pane`: an agent on a Cloud machine asking whoever is looking to open a browser pane.
///
/// **It asks. It cannot open anything, and the name says so.** A pane belongs to the window of
/// whoever has the workspace open, and that window is on somebody's Mac while this is running in a
/// datacentre. The Mac's own `pane_open` opens a pane and can say it did; this can only send a
/// request down the event stream and count who was told.
///
/// **The name is `request_pane` rather than `pane_open` deliberately, and the cost was weighed.**
/// `pane_open` is the name the model already knows, so it is the discoverable one, and discovery is
/// exactly what was wrong here before `BridgeBriefing` existed. But an agent that calls something
/// named `pane_open` writes "I opened a browser pane" in a transcript the owner reads, and when
/// nobody was looking that is a lie in the one place he is trusting. The briefing lists the tools,
/// generated from the toolbox, so the unfamiliar name costs nothing to find.
///
/// **Nobody may be looking, and the answer says so plainly.** A machine runs with every window
/// shut. A tool that reported success into an empty room would send the agent off believing it had
/// shown somebody something, which is worse than having no tool at all: that was the argument for
/// not building this, and answering it honestly is what made it buildable.
///
/// **Several people may be looking**, on a Mac and in the web client at once, so the request names
/// no window and every client decides for itself.
///
/// Browser panes only, for now. A terminal pane on a Cloud workspace is a different thing to want
/// and it can be added when somebody wants it.
public struct RequestPaneTool: BridgeToolHandling {
    /// Sends the request and answers how many connected clients were told. Zero is a real answer.
    /// Where the asker wants it. **`pane_split` and `pane_open` are the two verbs an agent already
    /// knows locally**, and until this existed a machine's agent could only produce the second
    /// while the tool's own name said pane: asked to put a browser next to a chat, it reported
    /// success and a tab appeared.
    public enum Placement: String, Sendable, Hashable {
        /// Beside the pane showing the chat that asked, when that chat is on screen.
        case split
        /// A tab of its own, which is what every client did before this existed.
        case tab
    }

    public typealias Requesting = @Sendable (
        _ url: String?, _ placement: Placement, _ sessionID: SessionID?, _ workspaceID: WorkspaceID
    ) async -> Int

    private let request: Requesting

    public init(_ request: @escaping Requesting) {
        self.request = request
    }

    public let roles: Set<BridgeRole> = [.workspace]

    public static let name = "request_pane"

    public let tool = BridgeTool(
        name: RequestPaneTool.name,
        description: """
            Ask whoever is looking at this workspace to open a browser pane beside the chat, at a \
            URL you name.

            This asks; it does not open. You are running on a machine, and a pane belongs to the \
            window of whoever has this workspace open, which is somewhere else. They may have it \
            closed, in which case nobody is asked and the answer says so: do not tell anybody you \
            opened something. More than one person may be looking, and they are all asked.

            Leave 'url' out to ask for this workspace's own public address, which is what the \
            preview shows. Pass one to point the pane somewhere else.

            'placement' is 'split' to ask for it beside the chat you are in, or 'tab' for a tab of \
            its own, which is the default. A client that cannot split, or whose reader is not \
            looking at this chat, opens a tab instead: what you get is theirs to decide, as ever.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "url": .object([
                    "type": .string("string"),
                    "description": .string("An http or https address. Omit for this workspace's own public URL."),
                ]),
                "placement": .object([
                    "type": .string("string"),
                    "enum": .array([.string("split"), .string("tab")]),
                    "description": .string("'split' for beside this chat, 'tab' for its own tab. Defaults to 'tab'."),
                ]),
            ]),
        ])
    )

    public func call(
        _ request: MCPRequest,
        as identity: BridgeIdentity,
        store: Store
    ) async -> BridgeToolResult {
        guard let workspaceID = identity.workspaceID else {
            return .failure("Only an agent working in a workspace can ask for a pane.")
        }
        var url: String?
        if let stated = request.stringParam("url")?.trimmingCharacters(in: .whitespacesAndNewlines), !stated.isEmpty {
            // The two schemes a pane can show. The rest are refused here for the reason
            // `BrowserPaneTool` refuses them on the Mac: a pane is a browser, and `file:` or
            // `javascript:` in one is a way to read the machine through a window somebody trusted.
            guard stated.hasPrefix("http://") || stated.hasPrefix("https://") else {
                return .failure("A pane can show an http or https address. \(stated) is neither.")
            }
            url = stated
        }
        // An unknown word is refused rather than quietly read as a tab: an agent that asked for
        // something this machine does not understand should be told, not answered with the default.
        let stated = request.stringParam("placement")?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let placement = stated.map({ Placement(rawValue: $0) }) ?? Placement.tab else {
            return .failure("A pane is placed 'split', beside this chat, or 'tab', in a tab of its own.")
        }
        let told = await self.request(url, placement, identity.sessionID, workspaceID)
        guard told > 0 else {
            return .init(text: "Nobody has this workspace open, so there was nobody to ask. "
                + "Nothing was opened. Say what you wanted to show and where it is served.")
        }
        let people = told == 1 ? "1 client" : "\(told) clients"
        let where_ = placement == .split ? " beside this chat" : " in a tab"
        return .init(text: "Asked \(people) looking at this workspace to open a browser pane\(where_)"
            + (url.map { " at \($0)" } ?? " at this workspace's public address")
            + ". Whether it opens, and where, is theirs to decide, so do not report it as done.")
    }
}
