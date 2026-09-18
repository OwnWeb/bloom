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
@MainActor
@Observable
final class CloudWorkspaceSession {
    let id: CloudWorkspaceID
    @ObservationIgnored unowned let cloud: CloudWorkspaces

    private(set) var state = CloudWorkspaceState()
    private(set) var phase: WorkspaceConnection.Phase = .closed
    private(set) var abilities: [String] = []
    /// The last command that failed where no dialog belongs, said once in a strip over the column,
    /// in runbloom.app's or the machine's own words and with the way back where there is one.
    var notice: CloudRefusalNotice?
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
    /// The branch's commits, read when the History tab is opened and a page at a time after that.
    @ObservationIgnored private(set) lazy var history = CloudHistory(session: self)
    /// Which setup states this workspace has already brought the tab forward for. See
    /// `SetupTabReveal`, which is where the rule is, under test.
    @ObservationIgnored private var setupReveal = SetupTabReveal()
    /// What GitHub says about the branch, read from runbloom.app rather than from this Mac's gh.
    @ObservationIgnored private(set) lazy var github = CloudPullRequestReader(session: self)
    /// Where the reader had got to in each conversation, per pane, which is what a local workspace
    /// keeps in `WorkspaceModel.panePositions` and for the same reason: the pane and the list that
    /// draw it are both destroyed by switching tab.
    @ObservationIgnored var panePositions: [TranscriptPaneState.Key: TranscriptPaneState] = [:]

    init(id: CloudWorkspaceID, cloud: CloudWorkspaces) {
        self.id = id
        self.cloud = cloud
    }

    var readerID: String? { cloud.account?.id }

    // MARK: The strip

    /// The machine's chats, in the order it lists them, which is what the strip is built from.
    var chatIDs: [SessionID] { state.topLevelChats.map { SessionID($0.id) } }

    /// The strip and the selection are `WorkspaceTabsStore`'s for both kinds of workspace, and the
    /// tool tabs are rows in `CenterTabStore` keyed by this workspace. What was a `CloudTabs` of
    /// its own is gone: the rules it held, which tabs there are, what they are called, what closing
    /// one selects next, were already the local column's rules asked twice.
    var selectedTab: PaneContent? { WorkspaceTabsStore.shared.selectedTab(in: self) }

    /// The chat in front, when the tab in front is one.
    var selectedChatID: SessionID? {
        if case .chat(let id) = selectedTab { return id }
        return nil
    }

    /// Whether the setup output is the tab in front, which is what stops the setup banner offering
    /// to show something already on screen.
    var isShowingSetup: Bool {
        guard case .tool(let id) = selectedTab else { return false }
        return CenterTabStore.shared.tabs(for: surfaceID).first { $0.id == id }?.kind == .setup
    }

    /// Opens the workspace's one tab of this kind, or brings it forward. One of each, the way a
    /// local workspace has one review and one set of notes: a second terminal on the same machine
    /// would be a second shell for the same person, which the machine does not offer.
    @discardableResult
    func open(_ kind: CenterTabKind) -> PaneContent {
        let store = CenterTabStore.shared
        let existing = store.tabs(for: surfaceID).first { $0.kind == kind }
        let tab = existing ?? store.add(kind: kind, workspaceID: surfaceID)
        let content = PaneContent.tool(tab.id)
        WorkspaceTabsStore.shared.reveal(content, in: self)
        if kind == .review { Task { await changes.refresh() } }
        return content
    }

    /// Closes a tab. A chat is closed on the machine as well, because it is the machine's.
    func close(_ content: PaneContent) {
        switch content {
        case .chat(let id):
            WorkspaceTabsStore.shared.prepareToClose(content, in: self)
            WorkspaceTabsStore.shared.forget(content, workspaceID: surfaceID)
            Task { await closeChat(id) }
        case .tool(let id):
            guard let tab = CenterTabStore.shared.tabs(for: surfaceID).first(where: { $0.id == id }) else { return }
            Task { await CenterTabStore.shared.close(tab, in: self) }
        }
    }

    func rename(_ content: PaneContent, to name: String) {
        switch content {
        case .chat(let id):
            Task { await run(.renameChat(chatID: id.rawValue, title: name), reporting: true) }
        case .tool(let id):
            guard let tab = CenterTabStore.shared.tabs(for: surfaceID).first(where: { $0.id == id }) else { return }
            CenterTabStore.shared.rename(tab, to: name)
        }
    }

    /// The setup tab, brought forward the first time a setup is running or has failed, so the one
    /// account of a machine's first few minutes is in front of whoever opened the workspace.
    func revealSetupIfNeeded() {
        guard setupReveal.shouldReveal(for: state.setup?.state) else { return }
        open(.setup)
    }

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
            revealSetupIfNeeded()
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
            if case .setup = event { revealSetupIfNeeded() }
            switch consequence {
            case .newChat(let chatID):
                // A chat somebody else started appears in the strip by itself, because the strip
                // is derived from the machine's list. It is only selected when there is nothing in
                // front, so a chat opened on another Mac cannot take the tab from under a reader.
                if selectedTab == nil {
                    WorkspaceTabsStore.shared.select(.chat(SessionID(chatID)), in: self)
                }
            case .composerChanged(let chatID, let author):
                if let author, author.userID != readerID { composerChange = (chatID, author.name) }
            case .reviewMoved:
                // Only while somebody has the review open: reading it is a request to the machine,
                // and a machine trying to sleep should not be asked for a list nothing is drawing.
                if CenterTabStore.shared.tabs(for: surfaceID).contains(where: { $0.kind == .review }) {
                    Task { await changes.refresh() }
                }
            default:
                break
            }
            if let chatID = Self.chatID(of: event) { forward(chatID) }
        case .skipped(let cursor):
            // The machine could not replay everything this Mac missed, which is what a runner that
            // restarted under an open window answers. The cursor moves on so the stream stays
            // usable, and every open chat is read again to fill what went past: rows are keyed by
            // `seq`, so a second copy replaces nothing.
            state.skip(cursor: cursor)
            for chatID in transcripts.keys { readHistory(chatID) }
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
        WorkspaceTabsStore.shared.select(.chat(SessionID(chat.id)), in: self)
    }

    func closeChat(_ id: SessionID) async {
        await run(.closeChat(chatID: id.rawValue))
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
            if reporting { report(error) }
            return error
        }
    }

    /// Says what failed in the words whoever refused it used, and offers runbloom.app when that is
    /// where the cause is settled: a missing key, GitHub, push access, a limit.
    func report(_ failure: WorkspaceConnection.CommandFailure) {
        if case .runbloom(let refusal) = failure {
            notice = CloudRefusalNotice(refusal: refusal)
            return
        }
        notice = CloudRefusalNotice(message: failure.message, code: failure.code?.rawValue)
    }

    private func runForResult(_ operation: WorkspaceOperation) async -> OperationResult? {
        do {
            return try await perform(operation)
        } catch {
            report(error)
            return nil
        }
    }

    /// Queues a message. Nil when the machine took it.
    func send(_ text: String, chatID: SessionID) async -> CloudSendOutcome {
        do {
            _ = try await perform(.send(chatID: chatID.rawValue, text: text))
            return .sent
        } catch {
            return CloudSendOutcome(failure: error)
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
                    notice = CloudRefusalNotice(
                        message: "Your first message could not be sent (\(wire.message)). It was: \(prompt.text)",
                        code: wire.knownCode.rawValue
                    )
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
                WorkspaceTabsStore.shared.select(.chat(SessionID(chat.id)), in: self)
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
                notice = CloudRefusalNotice(
                    message: "runbloom.app gave a preview address that is not this Cloud workspace's, so Bloom did not open it.", code: nil
                )
                return
            }
            NSWorkspace.shared.open(preview.enterURL)
        } catch let refusal as RunbloomRefusal {
            if refusal.isSharingInProgress || refusal.isMachineNotReady {
                notice = CloudRefusalNotice(message: "\(refusal.message) Try the preview again in a few seconds.", code: nil)
                return
            }
            if let limit = LimitNotice(refusal: refusal) {
                notice = CloudRefusalNotice(message: "\(limit.message) \(limit.detail)", code: refusal.code)
                return
            }
            notice = CloudRefusalNotice(refusal: refusal)
        } catch {
            notice = CloudRefusalNotice(message: "The preview could not be opened. \(error.localizedDescription)", code: nil)
        }
    }
}
