import BloomProtocol
import Foundation

/// The first message of a Bloom Cloud workspace an agent created, handed over once by runbloom.app.
///
/// **A written exception to "runbloom.app never proxies agent traffic"**, approved by Freek on 18
/// September 2026 and bounded the way he approved it: held encrypted against this workspace,
/// fetched once by this machine with its own secret, and gone once this machine says it has it.
///
/// **The turn is runbloom.app's, registered at creation for the person whose agent asked.** A
/// machine cannot register a turn without a person's session token and never will; it can run one
/// runbloom.app registered, through the same `turns/{id}/start` every turn goes through, which is
/// where the key and the limits are decided.
public struct RemoteOpening: Codable, Sendable, Hashable {
    public struct Attachment: Codable, Sendable, Hashable {
        public var path: String
        public var name: String
        public var data: Data

        public init(path: String, name: String, data: Data) {
            self.path = path
            self.name = name
            self.data = data
        }
    }

    public struct PromptedBy: Codable, Sendable, Hashable {
        public var userID: String
        public var name: String?
        public var handle: String?

        public init(userID: String, name: String? = nil, handle: String? = nil) {
            self.userID = userID
            self.name = name
            self.handle = handle
        }

        enum CodingKeys: String, CodingKey {
            case name, handle
            case userID = "user_id"
        }
    }

    public var turnID: String
    public var prompt: String
    /// The creating chat's controls. **A key that is absent means this machine's own default** for
    /// it, so the object is merged over `composer_defaults` rather than read as a whole.
    public var controls: [String: WireValue]
    public var promptedBy: PromptedBy
    /// Files held with a web-created workspace until its machine can write them into the worktree.
    public var attachments: [Attachment]

    public init(turnID: String, prompt: String, controls: [String: WireValue], promptedBy: PromptedBy,
                attachments: [Attachment] = []) {
        self.turnID = turnID
        self.prompt = prompt
        self.controls = controls
        self.promptedBy = promptedBy
        self.attachments = attachments
    }

    enum CodingKeys: String, CodingKey {
        case prompt, controls, attachments
        case turnID = "turn_id"
        case promptedBy = "prompted_by"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        turnID = try values.decode(String.self, forKey: .turnID)
        prompt = try values.decode(String.self, forKey: .prompt)
        controls = try values.decode([String: WireValue].self, forKey: .controls)
        promptedBy = try values.decode(PromptedBy.self, forKey: .promptedBy)
        attachments = try values.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
    }

    /// Where a fetched opening waits between being fetched and being queued, so a machine that
    /// stops in between still has it: runbloom.app forgets it once told this machine has it.
    static let storedKey = "remote.opening"
    /// The turn of the opening this machine queued. **An opening is queued once, ever**: one whose
    /// acknowledgement was lost is fetched again on the next boot, by which time its turn may have
    /// run and left no queued prompt to recognise it by, and queueing it again opened a second chat
    /// that runbloom.app then refused to start.
    static let deliveredKey = "remote.opening.delivered"
}

extension WorkspaceRuntime {
    /// Keeps the opening where a restart finds it. The first half of the hand-off; runbloom.app is
    /// told this machine has it only after this returns.
    /// Whether the opening for this turn has already been queued here. See `deliveredKey`.
    public func hasDeliveredOpening(turnID: String) async throws -> Bool {
        try await store.setting(RemoteOpening.deliveredKey) == turnID
    }

    public func storeOpening(_ opening: RemoteOpening) async throws {
        let text = String(decoding: try JSONEncoder().encode(opening), as: UTF8.self)
        try await store.setSetting(RemoteOpening.storedKey, text)
    }

    /// Opens a chat on the opening's controls and queues its prompt under its person and its turn,
    /// then forgets the stored copy. Nothing to do when nothing is stored.
    ///
    /// **Once per turn, whatever happens around it.** A machine that queued the prompt and stopped
    /// before forgetting the copy finds it again on the next boot, and the turn it names is already
    /// waiting in a chat's queue, so the copy is forgotten rather than queued twice.
    ///
    /// Held behind setup like every prompt, so it runs once the project is installed, and runs
    /// after a failed setup too, so the person sees why their instruction went wrong rather than
    /// silence.
    @discardableResult
    public func deliverStoredOpening() async throws -> SessionID? {
        guard let text = try await store.setting(RemoteOpening.storedKey),
              let opening = try? JSONDecoder().decode(RemoteOpening.self, from: Data(text.utf8)) else { return nil }
        if try await hasDeliveredOpening(turnID: opening.turnID) {
            try await store.setSetting(RemoteOpening.storedKey, nil)
            return nil
        }
        for chat in try await chatIDs()
        where try await store.pendingDeliveries(sessionID: chat).contains(where: { $0.remoteTurnID == opening.turnID }) {
            try await store.setSetting(RemoteOpening.storedKey, nil)
            return chat
        }
        var prompt = opening.prompt
        if !opening.attachments.isEmpty {
            let workspace = try await workspace()
            for attachment in opening.attachments {
                let token = AttachmentDraft.token(for: attachment.path)
                guard prompt.contains(token) else { continue }
                let path = try RemoteFileOperations.upload(workspace: workspace, name: attachment.name, data: attachment.data)
                prompt = prompt.replacingOccurrences(of: token, with: AttachmentDraft.token(for: path))
            }
        }
        let controls = try await openingControls(opening.controls)
        let author = MessageAuthor(userID: opening.promptedBy.userID, name: opening.promptedBy.name ?? "")
        let chat = try await newChat(controls, as: RemoteCaller(author: author, abilities: ["view", "prompt"], sessionToken: nil))
        let session = try chat.id.sessionID
        try await queue().enqueue(Delivery(
            targetSessionID: session, body: prompt, interactionMode: InteractionMode(rawValue: controls.interactionMode),
            author: author, remoteTurnID: opening.turnID
        ))
        // Marked before the kept copy goes, so no order of stopping leaves it queueable again.
        try await store.setSetting(RemoteOpening.deliveredKey, opening.turnID)
        try await store.setSetting(RemoteOpening.storedKey, nil)
        return session
    }

    /// The opening's controls laid over what a new chat here would start with, key by key.
    func openingControls(_ given: [String: WireValue]) async throws -> ComposerControlsRecord {
        let defaults = try await newChatControls().record
        guard case .object(var merged) = try JSONDecoder().decode(WireValue.self, from: try JSONEncoder().encode(defaults)) else {
            return defaults
        }
        for (key, value) in given where value != .null { merged[key] = value }
        return try JSONDecoder().decode(ComposerControlsRecord.self, from: try JSONEncoder().encode(WireValue.object(merged)))
    }
}
