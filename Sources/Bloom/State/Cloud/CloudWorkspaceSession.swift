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
    /// Each chat's streaming text, outside `state` and outside observation. A delta arrives per few
    /// tokens, and written into `state` it redrew everything that reads the workspace (the header,
    /// the pane strip) on each one; only the chat's own transcript model needs it.
    @ObservationIgnored private var streaming: [String: String] = [:]
    /// The reader's own terminal, made the first time the pane is shown and kept, with its
    /// scrollback, for as long as the workspace is open.
    @ObservationIgnored private(set) lazy var terminal = CloudTerminal(session: self)
    /// The Changes pane's files and patches, read when the pane is looked at.
    @ObservationIgnored private(set) lazy var changes = CloudChanges(session: self)

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

    /// Closes the stream of a workspace that is no longer on screen, keeping everything it read.
    /// Opening it again resumes from where it stopped. See `WorkspaceConnection.suspend`.
    func suspend() {
        terminal.close()
        if let connection { Task { await connection.suspend() } }
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
                // A history read that failed while the workspace could not be reached is tried
                // again now that it can.
                for chatID in transcripts.keys where state.chats[chatID]?.hasReadHistory != true { readHistory(chatID) }
                // Not awaited: this loop is what drains the stream, and the opening prompt can take
                // a minute on a machine that is still waking.
                Task { await sendOpeningPromptIfHeld() }
            }
            if case .archived = next {
                Task { await cloud.refresh(id) }
            }
        case .snapshot(let snapshot):
            state.absorb(snapshot)
            if selectedChatID.map({ state.chats[$0.rawValue] == nil }) ?? true {
                selectedChatID = state.topLevelChats.last.map { SessionID($0.id) }
            }
            for chat in state.chatOrder { forward(chat) }
        case .event(.stream(let chatID, let text, let snapshot)):
            let next = snapshot ? text : (streaming[chatID] ?? "") + text
            streaming[chatID] = next
            transcripts[chatID]?.receiveCloudStreaming(next)
        case .event(let event):
            if case .message(let message) = event, message.kind == "assistantText" || message.kind == "result" {
                streaming[message.chatID] = ""
            }
            let consequence = state.apply(event)
            switch consequence {
            case .newChat(let chatID):
                if selectedChatID == nil { selectedChatID = SessionID(chatID) }
            case .composerChanged(let chatID, let author):
                if let author, author.userID != readerID { composerChange = (chatID, author.name) }
            case .reviewMoved:
                if pane == .changes { Task { await changes.refresh() } }
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
        transcript.receiveCloud(chat, streaming: streaming[chatID] ?? "", workspaceID: id, readerID: readerID)
    }

    /// A session token, fetched through the connection so every stream on this workspace shares
    /// one. Nil when runbloom.app will not issue one, which the banner already says why.
    func sessionToken(forceRefresh: Bool = false) async -> SessionToken? {
        if connection == nil { open() }
        return try? await connection?.currentToken(forceRefresh: forceRefresh)
    }

    // MARK: Chats

    /// The transcript model for a chat when one has been made. Safe from a view's body: it reads a
    /// dictionary outside observation and writes nothing.
    func existingTranscript(for id: SessionID) -> TranscriptModel? {
        transcripts[id.rawValue]
    }

    /// The transcript model for a chat, made on first use, with its history read. Writes
    /// observable state, so it is called from a task and never from a body.
    @discardableResult
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
                guard phase == .live || phase == .closed || phase.isConnecting,
                      let result = try? await perform(.transcript(chatID: chatID, afterSeq: after, limit: 500)),
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
        var attempts = 0
        while true {
            let next = prompt.nextOperation
            let result: OperationResult
            do {
                result = try await perform(next.operation, commandID: next.commandID)
            } catch {
                if case .refused(let wire) = error {
                    // Refused outright. Said once, with the words, so nothing typed is lost, and
                    // not tried again.
                    notice = "Your first message could not be sent (\(wire.message)). It was: \(prompt.text)"
                    cloud.release(promptFor: id.rawValue)
                    return
                }
                // No answer, or runbloom.app not ready to hand out a token. Tried again while the
                // workspace stays connected, backing off, under the same command id.
                attempts += 1
                guard phase == .live, attempts < 6 else { return }
                try? await Task.sleep(for: .seconds(5 * attempts))
                guard phase == .live else { return }
                continue
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
            guard preview.isSafe(forMachine: await connection?.machineURL) else {
                notice = "runbloom.app gave a preview address that is not this Cloud workspace's, so Bloom did not open it."
                return
            }
            NSWorkspace.shared.open(preview.enterURL)
        } catch let refusal as RunbloomRefusal {
            notice = LimitNotice(refusal: refusal).map { "\($0.message) \($0.detail)" } ?? refusal.message
        } catch {
            notice = "The preview could not be opened. \(error.localizedDescription)"
        }
    }
}
