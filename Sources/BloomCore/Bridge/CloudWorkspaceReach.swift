import Foundation

/// A Bloom Cloud workspace the signed-in person can open, as the bridge tools name one.
public struct CloudWorkspaceTarget: Sendable, Hashable {
    /// runbloom.app's id for it, which is what an agent passes back.
    public let id: String
    public let name: String
    /// runbloom.app's lifecycle word: `running`, `idle`, `setting_up` and the rest.
    public let state: String
    /// The GitHub repository it works on, `owner/name`, or empty where runbloom.app did not say.
    public let repository: String
    public let branch: String

    public init(id: String, name: String, state: String, repository: String = "", branch: String = "") {
        self.id = id
        self.name = name
        self.state = state
        self.repository = repository
        self.branch = branch
    }
}

/// One chat on a Bloom Cloud machine, as the chat tools list one.
public struct CloudChatSummary: Sendable, Hashable {
    public let id: String
    public let title: String
    public let agent: String
    public let state: String
    public let parentChatID: String?
    public let lastSeq: Int
    public let updatedAt: Date

    public init(
        id: String, title: String, agent: String, state: String,
        parentChatID: String? = nil, lastSeq: Int = 0, updatedAt: Date = .distantPast
    ) {
        self.id = id
        self.title = title
        self.agent = agent
        self.state = state
        self.parentChatID = parentChatID
        self.lastSeq = lastSeq
        self.updatedAt = updatedAt
    }
}

/// What a Bloom Cloud workspace has changed, measured by its machine the way `workspace_diff`
/// measures a local one: everything since the branch left its base.
public struct CloudWorkspaceChanges: Sendable, Hashable {
    public let branch: String
    public let baseBranch: String
    public let files: [ChangedFile]

    public init(branch: String, baseBranch: String, files: [ChangedFile]) {
        self.branch = branch
        self.baseBranch = baseBranch
        self.files = files
    }
}

/// Why a Bloom Cloud workspace could not be reached, in the machine's or the app's own sentence.
public struct CloudReachTrouble: Error, Sendable, Equatable {
    public let sentence: String
    public init(_ sentence: String) { self.sentence = sentence }
}

/// The Mac's way into the Bloom Cloud workspaces the signed-in person can open, for the bridge
/// tools that read or write another workspace.
///
/// **The seam, not the connection.** The connection to each machine, the token it is opened with
/// and the list runbloom.app gave are all the app's, on the main actor, so the tools are handed
/// these closures and nothing else, exactly as `workspace_start` is handed the app's half. What a
/// tool decides (which workspace a name means, which chat a message goes to, what may be sent and
/// what is left out of a transcript) is decided in the core, where it is tested.
///
/// **As the signed-in person, and only where runbloom.app says they may go.** `workspaces` is the
/// list the sidebar draws, less anything the person cannot open. The machine checks the token on
/// every call anyway; the Mac simply never offers what it cannot reach.
///
/// **Absent means no Cloud at all**: every tool that takes one behaves exactly as before with nil,
/// which is what the standard toolbox and the tests pass.
public struct CloudWorkspaceReach: Sendable {
    public var workspaces: @Sendable () async -> [CloudWorkspaceTarget]
    public var chats: @Sendable (_ workspace: String) async -> Result<[CloudChatSummary], CloudReachTrouble>
    /// A chat's rows after `afterSeq`, at most `limit`, in order, and whether the machine has more.
    public var transcript: @Sendable (_ workspace: String, _ chat: String, _ afterSeq: Int, _ limit: Int) async
        -> Result<(messages: [Message], hasMore: Bool), CloudReachTrouble>
    /// Puts a prompt in a chat. True when it started a turn, false when it waits in the queue.
    public var send: @Sendable (_ workspace: String, _ chat: String, _ text: String) async -> Result<Bool, CloudReachTrouble>
    public var changes: @Sendable (_ workspace: String) async -> Result<CloudWorkspaceChanges, CloudReachTrouble>
    public var patch: @Sendable (_ workspace: String, _ path: String) async -> Result<String, CloudReachTrouble>
    /// What has been sent to Bloom Cloud workspaces from here, for `WorkspaceSayThrottle`. A local
    /// message is its own row in the store and the throttle reads those; a Cloud one is not, so
    /// the same rule reads this instead.
    public let sent: CloudSayLedger

    public init(
        workspaces: @escaping @Sendable () async -> [CloudWorkspaceTarget],
        chats: @escaping @Sendable (String) async -> Result<[CloudChatSummary], CloudReachTrouble>,
        transcript: @escaping @Sendable (String, String, Int, Int) async
            -> Result<(messages: [Message], hasMore: Bool), CloudReachTrouble>,
        send: @escaping @Sendable (String, String, String) async -> Result<Bool, CloudReachTrouble>,
        changes: @escaping @Sendable (String) async -> Result<CloudWorkspaceChanges, CloudReachTrouble>,
        patch: @escaping @Sendable (String, String) async -> Result<String, CloudReachTrouble>,
        sent: CloudSayLedger = CloudSayLedger()
    ) {
        self.workspaces = workspaces
        self.chats = chats
        self.transcript = transcript
        self.send = send
        self.changes = changes
        self.patch = patch
        self.sent = sent
    }

    /// The Bloom Cloud workspace a name or an id means, when no local one does.
    ///
    /// By id first and then by exact name, the order `BridgeWorkspaceLookup` uses for local ones,
    /// and two with one name are refused rather than guessed between, for the same reason.
    public func find(_ given: String) async -> CloudWorkspaceLookup {
        CloudWorkspaceLookup.find(given, among: await workspaces())
    }
}

public enum CloudWorkspaceLookup: Sendable, Equatable {
    case found(CloudWorkspaceTarget)
    case ambiguous([CloudWorkspaceTarget])
    case unknown

    public static func find(_ given: String, among targets: [CloudWorkspaceTarget]) -> CloudWorkspaceLookup {
        if let byID = targets.first(where: { $0.id == given }) { return .found(byID) }
        let named = targets.filter { $0.name == given }
        switch named.count {
        case 0: return .unknown
        case 1: return .found(named[0])
        default: return .ambiguous(named)
        }
    }
}

/// Which chat a message to a Bloom Cloud workspace goes to: the most recently active top-level
/// chat, which is the machine's equivalent of the chat a local workspace has open.
///
/// A subagent's or a crew member's chat is never chosen, because a message to the workspace is a
/// message to its agent, not to a helper it started.
public enum CloudChatChoice {
    public static func target(among chats: [CloudChatSummary]) -> CloudChatSummary? {
        chats.filter { $0.parentChatID == nil }.max { $0.updatedAt < $1.updatedAt }
    }
}

/// Messages sent from this Mac to Bloom Cloud workspaces, kept for as long as the throttle looks
/// back and no longer.
public actor CloudSayLedger {
    public struct Entry: Sendable, Equatable {
        public let source: WorkspaceID
        public let target: String
        public let text: String
        public let at: Date
    }

    private var entries: [Entry] = []

    public init() {}

    public func record(from source: WorkspaceID, to target: String, text: String, at: Date = Date()) {
        entries.append(Entry(source: source, target: target, text: text, at: at))
        let since = at.addingTimeInterval(-WorkspaceSayThrottle.window)
        entries.removeAll { $0.at < since }
    }

    public func recent(from source: WorkspaceID, to target: String) -> [(text: String, at: Date)] {
        entries.filter { $0.source == source && $0.target == target }.map { ($0.text, $0.at) }
    }
}
