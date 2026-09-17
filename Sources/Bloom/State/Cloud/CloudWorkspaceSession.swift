import AppKit
import BloomClient
import BloomCore
import BloomProtocol
import Observation

/// One open Cloud workspace: its connection to the machine, everything the machine has said, and
/// the transcript model for each of its chats.
///
/// **The connection's rules are `WorkspaceConnection`'s and the merging rules are
/// `CloudWorkspaceState`'s**, both in `BloomClient`, where they are tested. What is left here is
/// the window's half: folding updates into observable state, handing each chat's slice to its
/// transcript model, reading history for the chats somebody looks at, and sending the opening
/// prompt a create left behind.
/// Which of a Cloud workspace's panes fills its column.
enum CloudPane: Hashable {
    case chat
    case terminal
    case changes
    case setup
}

@MainActor
@Observable
final class CloudWorkspaceSession {
    let id: CloudWorkspaceID
    @ObservationIgnored private unowned let cloud: CloudWorkspaces

    private(set) var state = CloudWorkspaceState()
    private(set) var phase: WorkspaceConnection.Phase = .closed
    private(set) var abilities: [String] = []
    /// The chat the column shows. Nil until the workspace has a chat.
    var selectedChatID: SessionID?
    var pane: CloudPane = .chat
    /// The last command that failed where no dialog belongs, said once in a strip over the column.
    var notice: String?
    /// Who last changed a chat's composer, when it was not the reader. Cleared when read.
    private(set) var composerChange: (chatID: String, name: String)?
    /// A new chat being opened.
    private(set) var isOpeningChat = false

    @ObservationIgnored private var connection: WorkspaceConnection?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var transcripts: [String: TranscriptModel] = [:]
    @ObservationIgnored private var historyReads: Set<String> = []
    @ObservationIgnored private var isSendingOpeningPrompt = false
    /// The reader's own terminal, made the first time the pane is shown and kept, with its
    /// scrollback, for as long as the workspace is open.
    @ObservationIgnored private(set) lazy var terminal = CloudTerminal(session: self)

    init(id: CloudWorkspaceID, cloud: CloudWorkspaces) {
        self.id = id
        self.cloud = cloud
    }

    var readerID: String? { cloud.account?.id }

    func allows(_ ability: String) -> Bool { abilities.contains(ability) }

    // MARK: Opening

    /// Opens the connection, unless it is open. Opening is what wakes a sleeping machine, so it is
    /// only called when somebody selects the workspace.
    func open() {
        if let connection {
            Task { await connection.resume() }
            return
        }
        let connection = WorkspaceConnection(workspaceID: id.rawValue, api: cloud.api)
        self.connection = connection
        listener = Task { [weak self] in
            for await update in connection.updates {
                guard let self else { return }
                await self.receive(update)
            }
        }
        Task { await connection.open() }
    }

    /// Wakes a machine that went to sleep, on the next thing somebody does.
    func wake() {
        guard let connection else { return open() }
        Task { await connection.resume() }
    }

    func close() {
        terminal.close()
        listener?.cancel()
        listener = nil
        if let connection { Task { await connection.close() } }
        connection = nil
        phase = .closed
    }

    private func receive(_ update: WorkspaceConnection.Update) async {
        switch update {
        case .phase(let next):
            phase = next
            if next == .live {
                abilities = await connection?.abilities ?? []
                await sendOpeningPromptIfHeld()
            }
            if case .archived = next {
                await cloud.refresh(id)
            }
        case .snapshot(let snapshot):
            state.absorb(snapshot)
            if selectedChatID.map({ state.chats[$0.rawValue] == nil }) ?? true {
                selectedChatID = state.topLevelChats.last.map { SessionID($0.id) }
            }
            for chat in state.chatOrder { forward(chat) }
        case .event(let event):
            let consequence = state.apply(event)
            switch consequence {
            case .newChat(let chatID):
                if selectedChatID == nil { selectedChatID = SessionID(chatID) }
            case .composerChanged(let chatID, let author):
                if let author, author.userID != readerID { composerChange = (chatID, author.name) }
            default:
                break
            }
            if let chatID = Self.chatID(of: event) { forward(chatID) }
        case .skipped(let cursor):
            state.skip(cursor: cursor)
        }
    }

    private static func chatID(of event: BloomProtocol.WorkspaceEvent) -> String? {
        switch event {
        case .message(let message): message.chatID
        case .stream(let chatID, _, _), .questions(let chatID, _), .composer(let chatID, _, _): chatID
        case .chat(let chat): chat.id
        case .queue(let queue): queue.chatID
        default: nil
        }
    }

    /// Hands a chat's slice of the state to its transcript model, when it has one.
    private func forward(_ chatID: String) {
        guard let transcript = transcripts[chatID], let chat = state.chats[chatID] else { return }
        transcript.receiveCloud(chat, workspaceID: id, readerID: readerID)
    }

    /// A session token, fetched through the connection so every stream on this workspace shares
    /// one. Nil when runbloom.app will not issue one, which the banner already says why.
    func sessionToken(forceRefresh: Bool = false) async -> SessionToken? {
        if connection == nil { open() }
        return try? await connection?.currentToken(forceRefresh: forceRefresh)
    }

    // MARK: Chats

    /// The transcript model for a chat, made on first use, with its history read.
    func transcript(for id: SessionID) -> TranscriptModel? {
        let chatID = id.rawValue
        if let existing = transcripts[chatID] { return existing }
        guard let record = state.chats[chatID]?.chat, let app = cloud.appModel else { return nil }
        let model = TranscriptModel(
            cloudChat: Session(cloudChat: record), link: CloudChatLink(chatID: id, session: self), app: app
        )
        transcripts[chatID] = model
        forward(chatID)
        readHistory(chatID)
        return model
    }

    /// Reads a chat's history a page at a time, from the start, until the machine says there is no
    /// more. Rows the stream delivers meanwhile are kept, and the pages fill in around them.
    private func readHistory(_ chatID: String) {
        guard historyReads.insert(chatID).inserted, state.chats[chatID]?.hasReadHistory != true else { return }
        Task {
            var after = -1
            while true {
                guard let result = try? await perform(.transcript(chatID: chatID, afterSeq: after, limit: 500)),
                      case .transcript(let page) = result else {
                    historyReads.remove(chatID)
                    return
                }
                let next = state.absorbPage(page)
                forward(chatID)
                guard let next else { return }
                after = next
            }
        }
    }

    /// Opens a new chat with the controls of the one on screen, or this Mac's defaults.
    func newChat() async {
        guard !isOpeningChat else { return }
        isOpeningChat = true
        defer { isOpeningChat = false }
        let controls: ComposerControlsRecord
        if let current = selectedChatID.flatMap({ state.chats[$0.rawValue]?.controls }) {
            controls = current
        } else {
            controls = await cloud.openingControls().cloudRecord
        }
        guard let result = await runForResult(.newChat(controls: controls)), case .chat(let chat) = result else { return }
        state.apply(.chat(chat))
        selectedChatID = SessionID(chat.id)
    }

    func closeChat(_ id: SessionID) async {
        guard await run(.closeChat(chatID: id.rawValue)) == nil else { return }
        if selectedChatID == id { selectedChatID = state.topLevelChats.last { $0.id != id.rawValue }.map { SessionID($0.id) } }
    }

    func acknowledgeComposerChange() { composerChange = nil }

    // MARK: Commands

    /// Sends one operation. Somebody doing something is what wakes a sleeping machine, so this
    /// resumes the connection first.
    func perform(_ operation: WorkspaceOperation, commandID: String = UUID().uuidString.lowercased()) async throws(WorkspaceConnection.CommandFailure) -> OperationResult {
        if connection == nil { open() }
        guard let connection else { throw .noAnswer("This Cloud workspace is closed.") }
        return try await connection.perform(operation, commandID: commandID)
    }

    /// Sends one operation for its effect. Answers the failure, which is also shown in the notice
    /// strip unless `reporting` is false because the caller says it somewhere better.
    @discardableResult
    func run(_ operation: WorkspaceOperation, reporting: Bool = true) async -> WorkspaceConnection.CommandFailure? {
        do {
            _ = try await perform(operation)
            return nil
        } catch {
            if reporting { notice = error.message }
            return error
        }
    }

    private func runForResult(_ operation: WorkspaceOperation) async -> OperationResult? {
        do {
            return try await perform(operation)
        } catch {
            notice = error.message
            return nil
        }
    }

    /// Queues a message. Nil when the machine took it.
    func send(_ text: String, chatID: SessionID) async -> String? {
        do {
            _ = try await perform(.send(chatID: chatID.rawValue, text: text))
            return nil
        } catch {
            return error.message
        }
    }

    /// Reads setup's whole log so far, which the stream only appends to from the moment it opened.
    /// Answers whether it was read.
    func readSetupOutput() async -> Bool {
        guard let result = try? await perform(.setupOutput), case .setupOutput(let record) = result else { return false }
        state.replaceSetupLog(record.log, setup: record.setup)
        return true
    }

    // MARK: The opening prompt

    /// The prompt typed when this workspace was created, if it has not gone yet.
    var heldPrompt: PendingOpeningPrompt? { cloud.pendingPrompts.prompts[id.rawValue] }

    /// Sends the held opening prompt: a chat of its own first, then the prompt into it, each under
    /// the command id kept with the prompt, so a relaunch or a dropped answer cannot do either twice.
    private func sendOpeningPromptIfHeld() async {
        guard var prompt = heldPrompt, !isSendingOpeningPrompt else { return }
        isSendingOpeningPrompt = true
        defer { isSendingOpeningPrompt = false }
        while true {
            let next = prompt.nextOperation
            let result: OperationResult
            do {
                result = try await perform(next.operation, commandID: next.commandID)
            } catch {
                // Not the machine's to decide yet, or it refused the prompt outright. A refusal is
                // said once and the prompt goes back into a draft rather than being tried for ever.
                if case .refused(let wire) = error {
                    notice = "The opening prompt could not be sent: \(wire.message)"
                    cloud.release(promptFor: id.rawValue)
                    if let chatID = prompt.chatID { transcripts[chatID]?.draft = prompt.text }
                }
                return
            }
            switch result {
            case .chat(let chat):
                state.apply(.chat(chat))
                selectedChatID = SessionID(chat.id)
                prompt.chatID = chat.id
                cloud.hold(prompt)
            case .queued:
                cloud.release(promptFor: id.rawValue)
                return
            default:
                return
            }
        }
    }

    // MARK: The preview

    /// Opens the project's app in the browser, top level, through a single use preview token.
    func openPreview() async {
        do {
            let preview = try await cloud.api.previewToken(for: id.rawValue)
            NSWorkspace.shared.open(preview.enterURL)
        } catch let refusal as RunbloomRefusal {
            notice = LimitNotice(refusal: refusal).map { "\($0.message) \($0.detail)" } ?? refusal.message
        } catch {
            notice = "The preview could not be opened. \(error.localizedDescription)"
        }
    }
}
