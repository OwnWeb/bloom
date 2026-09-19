import BloomProtocol
import Foundation

/// Whether a message from an agent on a Bloom Cloud machine may go into a workspace on this Mac,
/// and what it goes in as.
///
/// **Every check is this Mac's to hold, although the machine has already made them.** The machine
/// sends a `mac_message` only down the event streams the running turn's person opened from Bloom on
/// a Mac, so a mismatch here is a bug somewhere rather than an attack; it is still refused, because
/// the whole of what makes this safe is that a message lands only in the work of the person whose
/// agent sent it, and only in a workspace that person has here.
///
/// **It goes in as a message from elsewhere, never as typed words.** It is a relayed message like
/// one `workspace_say` puts in a chat, in the same untrusted envelope, headed with where it came
/// from, and it does not carry the owner's authority: see `WorkspaceMessage.fromBloomCloud`.
///
/// **Once per id.** A Mac with two streams open to the same machine is sent it twice.
public enum MacMessageIntake {
    public enum Decision: Equatable, Sendable {
        case deliver(WorkspaceMessage)
        /// Dropped, with the sentence the log keeps. Nothing goes back: there is no reply channel,
        /// and the machine's agent was already told the Mac decides.
        case drop(String)
    }

    /// - Parameters:
    ///   - signedIn: the account signed in on this Mac, or nil when nobody is.
    ///   - workspaces: this Mac's active workspaces, which is what a name is resolved among, the
    ///     way `workspace_say` resolves one.
    ///   - projects: their projects' names, for the message's heading.
    ///   - seen: whether this id has been delivered already.
    public static func decide(
        _ record: MacMessageRecord,
        signedIn: String?,
        workspaces: [Workspace],
        projects: [RepoID: String] = [:],
        seen: Bool
    ) -> Decision {
        guard !seen else { return .drop("mac_message \(record.id) was already delivered.") }
        guard let signedIn, record.userID == signedIn else {
            return .drop("mac_message \(record.id) is for another account than the one signed in here.")
        }
        guard record.via.kind == ViaRecord.agent else {
            return .drop("mac_message \(record.id) says it came from something other than an agent.")
        }
        let target: Workspace
        switch BridgeWorkspaceLookup.find(record.workspace, among: workspaces.filter { $0.state != .archived }) {
        case .found(let found): target = found
        case .ambiguous: return .drop("mac_message \(record.id) names '\(record.workspace)', which more than one workspace is called.")
        case .unknown: return .drop("mac_message \(record.id) names '\(record.workspace)', which no workspace here is called.")
        }
        let cloudWorkspace = label(record.via.workspace) ?? "a Bloom Cloud workspace"
        let chat = label(record.via.chat) ?? ""
        // The heading the receiving chat draws, "From an agent in Queue retries · Chat, Bloom
        // Cloud", is `workspace`; the Cloud workspace's own name is kept in `project` for the
        // envelope, which names it on its own and tells the agent how to answer.
        let heading = "an agent in " + ([cloudWorkspace, chat].filter { !$0.isEmpty }.joined(separator: " \u{00B7} "))
            + ", Bloom Cloud"
        var message = WorkspaceMessage(
            id: WorkspaceMessageID(record.id),
            source: WorkspaceMessageEnd(workspaceID: nil, workspace: heading, project: cloudWorkspace, chat: chat),
            target: WorkspaceMessageEnd(
                workspaceID: target.id, workspace: target.name, project: projects[target.repoID] ?? ""
            ),
            text: record.text
        )
        message.fromBloomCloud = true
        return .deliver(message)
    }

    /// A name off the wire, trimmed and bounded the way the machine bounds it. Empty is nil.
    private static func label(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : String(trimmed.prefix(200))
    }
}

/// The ids already delivered, so a message sent down two streams goes in once. Bounded, because it
/// only has to outlast the moment both copies are in flight.
public struct MacMessageLedger: Sendable {
    private var order: [String] = []
    private var ids: Set<String> = []
    static let limit = 500

    public init() {}

    public func contains(_ id: String) -> Bool { ids.contains(id) }

    public mutating func insert(_ id: String) {
        guard ids.insert(id).inserted else { return }
        order.append(id)
        if order.count > Self.limit { ids.remove(order.removeFirst()) }
    }
}
