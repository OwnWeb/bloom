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
    /// When this window saw each step of the workspace's build begin and end. See
    /// `CloudWorkspaceSession+Setup.swift`.
    var setupClock = CloudSetupClock()
    /// Closed chats the machine currently offers back through the shared new-tab menu.
    private(set) var closedChats: [ClosedChat] = []

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
    /// The chat somebody pointed the review's composer at, when they picked one. See
    /// `WorkspaceSurface.reviewDestination`.
    var chosenReviewDestination: SessionID?
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

    /// The account doing the reading, which is what decides whether a message is the reader's own.
    /// See `MessageAuthorship.isFromSomebodyElse`, which is the only thing that should ask.
    ///
    /// **The token's own id first, the signed in account behind it.** A session token is fetched
    /// to open the connection, so `user_id` is here from the first request, where an account
    /// object arrives whenever the sign in finishes. That order is the whole point: the window it
    /// closes is between launch and the account arriving, where a workspace somebody else is in
    /// drew the reader's own messages in the colour reserved for a teammate and captioned them
    /// with their own name.
    ///
    /// **The field, never the token's `sub`**, even though the value is the same one and
    /// runbloom.app has a test pinning the two together. Parsing the token would give this client
    /// an opinion about its shape that everybody afterwards has to keep, for a value that is
    /// handed over anyway. It is `user_id` rather than `subject` because that is already what the
    /// member list and `author.user_id` call it, and the comparison this feeds is against
    /// `author.user_id`: one id, one name, everywhere it appears.
    ///
    /// **Not a field every client ought to want.** The web's account arrives server rendered
    /// before the first paint, so the token's id would reach it later rather than earlier. This is
    /// for a client that authenticates before it renders, which is this one and only this one
    /// today.
    ///
    /// The account stays as the fallback for a control server too old to send it. A share-link
    /// guest is not a case either way: a preview token cannot open a chat or send, so there are no
    /// guest-written messages whose ownership could be got wrong. See
    /// `MessageAuthorship.isFromSomebodyElse`, which is the only thing that should ask.
    var readerID: String? { tokenUserID ?? cloud.account?.id }

    /// Who the connection's current token was minted for, cached as the phase moves because
    /// `readerID` is read from view bodies and the connection is an actor.
    private(set) var tokenUserID: String?

    #if DEBUG
    /// One chat, put into this workspace without a machine to have sent it.
    ///
    /// Here rather than in the probe because `state` is `private(set)` and this file is the only
    /// one that may write it. See `CloudSelectionProbe`, which needs a workspace that goes from no
    /// chats to one, since the two answer differently and the crash it is about was in the first.
    func absorbForProbe(chat id: String) {
        _ = state.apply(.chat(ChatRecord(
            id: id, title: "Probe", agent: "claude", model: "", effort: "", permissionMode: "",
            interactionMode: "", state: "idle", lastSeq: 0, createdAt: .now, updatedAt: .now
        )))
    }
    #endif

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
        if kind == .review {
            Task { await changes.refresh() }
            changes.reconsiderWatching()
        }
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
            Task {
                await CenterTabStore.shared.close(tab, in: self)
                // The review tab going is one fewer reader, and with the inspector on another tab
                // it is the last one: the held read stops rather than waiting on a machine for a
                // list nothing is drawing.
                changes.reconsiderWatching()
            }
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

    func allows(_ ability: String) -> Bool { abilities.contains(ability) }

    /// Whether this workspace has a review tab at all, which is what every read of the machine's
    /// changes is gated on. Reading them is a request to the machine, and a machine trying to sleep
    /// should not be asked for a list nothing is drawing.
    var hasReviewTab: Bool {
        CenterTabStore.shared.tabs(for: surfaceID).contains { $0.kind == .review }
    }

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
    ///
    /// - Parameter announcing: whether somebody asked for this one, which makes it worth saying so
    ///   on screen. See `WorkspaceConnection.resume(announcing:)`.
    func wake(announcing: Bool = false) {
        guard let connection else { return open() }
        Task { await connection.resume(announcing: announcing) }
    }

    /// Closes the stream of a workspace that is no longer on screen, keeping everything it read.
    /// Opening it again resumes from where it stopped. See `WorkspaceConnection.suspend`.
    func suspend() {
        terminal.close()
        if let connection { Task { await connection.suspend() } }
    }

    func close() {
        changes.stopWatching()
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
            // Read on every phase rather than only on `.live`: the token is fetched to open the
            // stream, so this is answerable while the connection is still connecting, and being
            // answerable early is the whole reason the field exists. See `readerID`.
            if let userID = await connection?.tokenUserID, userID != tokenUserID { tokenUserID = userID }
            if next == .live {
                abilities = await connection?.abilities ?? []
                // A history read that failed while the workspace could not be reached is tried
                // again now that it can.
                for chatID in transcripts.keys where state.chats[chatID]?.hasReadHistory != true { readHistory(chatID) }
                // Not awaited: this loop is what drains the stream, and the opening prompt can take
                // a minute on a machine that is still waking.
                Task { await sendOpeningPromptIfHeld() }
                // A stream coming up is one of the moments runbloom.app is asked for what it held
                // while no stream was open. See `AppModel.drainMacMessages`.
                Task { await cloud.appModel?.drainMacMessages() }
                // What changed, once, on the way up.
                //
                // **Not gated on a review tab any more, and the gate was a bug.** It was, on the
                // argument that a machine trying to sleep should not be asked for a list nothing
                // is drawing. But the inspector's Changes tab draws that list too and asks nobody
                // for it: a local workspace has `AppModel`'s poll behind it, and a Cloud one had
                // only the review tab, so somebody sitting in the inspector with no review tab
                // open watched "Reading the worktree" spin for ever. The workspace whose
                // connection has just gone live is one somebody is looking at, so the read is
                // wanted. Later turns refresh it when they finish.
                Task { await changes.refresh() }
                changes.reconsiderWatching()
                Task { await refreshClosedChats() }
                // **And the setup log, which nothing was ever asking for.** The stream only
                // appends what happens after it opens, so a workspace opened after its setup had
                // finished had no log at all: `setup_output` exists for exactly this and had no
                // caller, which is why the owner met a finished setup row with nothing behind its
                // chevron. Asked once, on the way up, and only where there is a setup to read and
                // nothing of it in hand.
                if let setup = state.setup, setup.state != "skipped", state.setupLog.isEmpty {
                    Task { _ = await readSetupOutput() }
                }
            }
            if next != .live { changes.stopWatching() }
            if case .archived = next {
                Task { await cloud.refresh(id) }
            }
        case .snapshot(let snapshot):
            state.absorb(snapshot)
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
                // A chat somebody else started appears in the strip by itself, because the strip
                // is derived from the machine's list. It is only selected when there is nothing in
                // front, so a chat opened on another Mac cannot take the tab from under a reader.
                if selectedTab == nil {
                    WorkspaceTabsStore.shared.select(.chat(SessionID(chatID)), in: self)
                }
            case .composerChanged(let chatID, let author):
                if let author, author.userID != readerID { composerChange = (chatID, author.name) }
            case .chatClosed(let chatID):
                let content = PaneContent.chat(SessionID(chatID))
                WorkspaceTabsStore.shared.prepareToClose(content, in: self)
                WorkspaceTabsStore.shared.forget(content, workspaceID: surfaceID)
                transcripts[chatID]?.teardown()
                transcripts[chatID] = nil
                streaming[chatID] = nil
                historyReads.remove(chatID)
                Task { await refreshClosedChats() }
            case .paneRequested(let url, let chatID, let placement):
                Task { await openRequestedPane(url: url, chatID: chatID, placement: placement) }
            case .macMessage(let record):
                Task { await cloud.appModel?.receiveMacMessage(record) }
            case .turnEnded:
                // A workspace that has just had files written to it is the definition of one whose
                // changes are stale. The chat state is the machine volunteering that, so the pane
                // is right after every turn.
                Task { await changes.refresh(quietly: changes.hasRead) }
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
        transcript.receiveCloud(chat, streaming: streaming[chatID] ?? "", workspaceID: id)
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
        // The chat in front, because a second chat is usually more of the same, and the machine's
        // own defaults otherwise. Never this Mac's where the machine has an answer: it has read the
        // repository's settings file and knows which agents are in its image, and neither is
        // visible from here.
        let controls: ComposerControlsRecord
        if let current = selectedChatID.flatMap({ state.chats[$0.rawValue]?.controls }) {
            controls = current
        } else {
            controls = await openingDefaults()
        }
        guard let result = await runForResult(.newChat(controls: controls)), case .chat(let chat) = result else { return }
        state.apply(.chat(chat))
        WorkspaceTabsStore.shared.select(.chat(SessionID(chat.id)), in: self)
    }

    func closeChat(_ id: SessionID) async {
        guard await run(.closeChat(chatID: id.rawValue)) == nil else { return }
        await refreshClosedChats()
    }

    /// Re-reads the bounded list the machine owns. A failed read keeps the last useful answer.
    func refreshClosedChats() async {
        guard let result = try? await perform(.recentlyClosed), case .recentlyClosed(let records) = result else { return }
        let offered = SessionReopening.offered(records.compactMap(ClosedChat.init(record:)))
        if closedChats != offered { closedChats = offered }
    }

    /// Reopens one of the machine's offered chats and brings its ordinary tab back to the front.
    func reopen(_ chat: ClosedChat) async {
        guard let result = await runForResult(.reopenChat(chatID: chat.id.rawValue)),
              case .chat(let record) = result else { return }
        _ = state.apply(.chat(record))
        WorkspaceTabsStore.shared.select(.chat(chat.id), in: self)
        await refreshClosedChats()
    }

    func acknowledgeComposerChange() { composerChange = nil }

    // MARK: Commands

    /// Sends one operation. Somebody doing something is what wakes a sleeping machine, so this
    /// resumes the connection first.
    func perform(_ operation: WorkspaceOperation, commandID: String = UUID().uuidString.lowercased()) async throws(WorkspaceConnection.CommandFailure) -> OperationResult {
        if connection == nil { open() }
        guard let connection else { throw .noAnswer("This Bloom Cloud workspace is closed.") }
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
            if reporting, error != .cancelled { report(error) }
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
            if error != .cancelled { report(error) }
            return nil
        }
    }

    /// Queues a message. Nil when the machine took it.
    /// - Parameter audience: who it is for, or nil for the agent, which is every message Bloom has
    ///   sent until now. A mention is carried rather than stripped: the machine takes it off the
    ///   text it hands the agent and nowhere else, so the transcript keeps what was typed and can
    ///   colour it. See `AudienceRecord`.
    func send(_ text: String, chatID: SessionID, audience: AudienceRecord? = nil) async -> CloudSendOutcome {
        do {
            _ = try await perform(.send(chatID: chatID.rawValue, text: text, audience: audience))
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

    /// What a new chat on this machine opens with: the machine's own answer where it gave one,
    /// and this Mac's choice, clamped to the agents a machine runs, where it did not.
    func openingDefaults() async -> ComposerControlsRecord {
        if let defaults = state.composerDefaults { return defaults }
        return await cloud.openingControls().cloudRecord
    }

    /// The prompt typed when this workspace was created, if it has not gone yet.
    var heldPrompt: PendingOpeningPrompt? { cloud.pendingPrompts.prompts[id.rawValue] }

    /// Sends the held opening prompt: a chat of its own first, then the prompt into it, each under
    /// the command id kept with the prompt, so a relaunch or a dropped answer cannot do either twice.
    private func sendOpeningPromptIfHeld() async {
        guard var prompt = heldPrompt, !isSendingOpeningPrompt else { return }
        isSendingOpeningPrompt = true
        defer { isSendingOpeningPrompt = false }
        // What the chat opens with when nobody chose in the create window: the machine's own
        // answer, which knows the repository's settings file and the agents in its image, and this
        // Mac's clamped choice for a machine too old to have one. Read once, here, because the
        // snapshot has landed by the time this runs: `sendOpeningPromptIfHeld` is called when the
        // connection goes live.
        let defaults = await openingDefaults()
        // The files it was typed with, which have been waiting on this Mac since before the
        // machine existed. Once, before the first send: `carrying` clears the staging id on the
        // held prompt, so a retry after a relaunch sends the sentence it has rather than uploading
        // the same screenshots again.
        if prompt.stagingDraftID != nil {
            prompt = await carrying(prompt)
            cloud.hold(prompt)
        }
        var attempts = 0
        while true {
            let next = prompt.nextOperation(defaults: defaults)
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

    /// Where the machine put a file, or why it did not take it.
    enum Upload {
        /// The path an agent on that machine reads it from, relative to its worktree.
        case at(String)
        case refused(String)
    }

    /// Copies a file into the workspace's attachment folder on the machine. Eight megabytes is the
    /// machine's own limit and its refusal is what gets shown, rather than a second limit here that
    /// could disagree with it. See `RemoteFileOperations.upload`.
    func upload(name: String, data: Data) async -> Upload {
        do {
            let result = try await perform(.uploadFile(name: name, data: data))
            guard case .text(let path) = result else {
                return .refused("The machine did not say where it put \(name).")
            }
            return .at(path)
        } catch {
            return .refused(error.message)
        }
    }

    /// The opening prompt with its files put on the machine and named where the machine put them.
    ///
    /// **A file that will not go is taken out of the sentence here, which is the opposite of what a
    /// chat message does and is the same choice the local create window already made.** There is no
    /// composer to give the words back to: the workspace exists, its machine is up, and the turn is
    /// the reason both were made. A path to a file the agent cannot open teaches it that Bloom lies
    /// about paths, so it goes, and the person is told which one did not make it. See
    /// `WorkspaceStartAttachments.opening`, which says the same thing about a worktree.
    private func carrying(_ prompt: PendingOpeningPrompt) async -> PendingOpeningPrompt {
        var prompt = prompt
        guard let draftID = prompt.stagingDraftID else { return prompt }
        prompt.stagingDraftID = nil
        let parsed = AttachmentDraft.parse(prompt.text)
        guard !parsed.paths.isEmpty else { return prompt }

        let root = AttachmentStaging.directory(draftID: draftID)
        var moved: [String: String] = [:]
        var lost: [String] = []
        for path in Set(parsed.paths) {
            let file = URL(filePath: (root as NSString).appendingPathComponent(path))
            guard let data = try? Data(contentsOf: file) else {
                lost.append((path as NSString).lastPathComponent)
                continue
            }
            switch await upload(name: (path as NSString).lastPathComponent, data: data) {
            case .at(let remote):
                moved[path] = remote
            case .refused:
                lost.append((path as NSString).lastPathComponent)
            }
        }
        prompt.text = parsed.mapping { moved[$0] }
        AttachmentStaging.discard(draftID: draftID)
        PromptAttachmentStore.shared.clear(sessionID: draftID)
        if !lost.isEmpty {
            notice = CloudRefusalNotice(
                message: lost.count == 1
                    ? "\(lost[0]) could not be sent to this Bloom Cloud workspace, so your first message does not name it."
                    : "These files could not be sent to this Bloom Cloud workspace, so your first message does not name them: \(lost.joined(separator: ", "))",
                code: nil
            )
        }
        return prompt
    }

    // MARK: A pane the agent asked for

    /// Where the preview pane goes when it is next opened, or nil for the app's own front page.
    ///
    /// Set by a request from the machine and cleared by the pane that honours it: a destination is
    /// a thing that happens once, and one left lying about would send the reader somewhere on the
    /// next open for a reason that has scrolled off the screen.
    private(set) var previewDestination: String?

    func tookPreviewDestination() -> String? {
        defer { previewDestination = nil }
        return previewDestination
    }

    /// What this Mac does about `pane_requested`.
    ///
    /// **Opened rather than asked about, and said rather than opened silently.** The local
    /// equivalent, `pane_open`, is on Bloom's own self-approved list, because it adds something the
    /// reader can see and close in the workspace whose agent is asking and nowhere else, and this
    /// is that same act over a connection. What it owes on top is an account of itself: a pane
    /// appearing on a desk is ordinary when you pressed something and is not ordinary otherwise,
    /// so the notice names the workspace it came from either way. See `CloudPaneRequest`.
    ///
    /// **A split goes beside the chat that asked, and only while that chat is on screen.** An agent
    /// asked to put a browser "next to this chat" used to get a tab, because the event carried no
    /// placement at all and the thing the owner asked for was not expressible; it carries one now.
    /// Where the asking chat is not the tab in front, this opens a tab instead and says so, because
    /// bringing that chat forward first would take away what the reader was reading, and moving
    /// somebody's selection on a machine's word is a bigger liberty than opening a pane.
    ///
    /// **The notice names what happened rather than what was asked for**, which is why the
    /// placement it is given is the one that came back from the attempt.
    private func openRequestedPane(url: String?, chatID: String?, placement: String?) async {
        let request = CloudPaneRequest.of(url: url, machineHost: await connection?.machineURL?.host())
        var placed = CloudPaneRequest.placement(
            placement, chatID: chatID,
            isChatOnScreen: chatID.map { WorkspaceTabsStore.shared.selectedTab(in: self) == .chat(SessionID($0)) } ?? false
        )
        if case .workspaceApp(let path) = request {
            previewDestination = path
            if case .split(let besideChat) = placed, !splitBrowser(beside: SessionID(besideChat)) {
                // The tab could not be split: a layout that cannot hold another pane, or a browser
                // tab that is itself the root of an arrangement. A tab is always possible and is
                // what the reader gets, so it is what the sentence says.
                placed = .tab
            }
            if placed == .tab { open(.browser) }
        }
        cloud.appModel?.notice = BloomNotice(
            message: CloudPaneRequest.sentence(request, workspace: surfaceName, placement: placed)
        )
    }

    /// Puts the workspace's browser in a pane beside a chat's, answering whether it went.
    ///
    /// The workspace's one browser rather than a second: `open(_:)`'s rule, for the same reason.
    /// A machine asking twice should move the pane it already has rather than filling the window
    /// with browsers.
    private func splitBrowser(beside chatID: SessionID) -> Bool {
        let store = CenterTabStore.shared
        let tab = store.tabs(for: surfaceID).first { $0.kind == .browser }
            ?? store.add(kind: .browser, workspaceID: surfaceID)
        return WorkspaceTabsStore.shared.split(
            tab: .chat(chatID), axis: .horizontal, showing: .tool(tab.id)
        ) != nil
    }

    // MARK: The preview

    /// Opens the project's app in the browser, top level, through a single use preview token.
    /// One preview address, checked, for a caller that will draw it rather than hand it to another
    /// application.
    ///
    /// **A separate answer from `openPreview` because the failure goes somewhere else.** Opening in
    /// a browser is a one-off, so a refusal is the column's notice strip; a pane that cannot open
    /// keeps the sentence where the pane is, with something to press. The exchange itself is the
    /// same and the safety check is the same, so they share this. See `CloudPreviewPane`.
    func previewEntry() async -> PreviewEntry {
        do {
            let preview = try await cloud.api.previewToken(for: id.rawValue)
            guard preview.isSafe(forMachine: await connection?.machineURL) else {
                return .refused("runbloom.app gave a preview address that is not this workspace's, so Bloom did not open it.")
            }
            return .address(preview.enterURL)
        } catch let refusal as RunbloomRefusal {
            if refusal.isSharingInProgress || refusal.isMachineNotReady {
                return .refused("\(refusal.message) Try again in a few seconds.")
            }
            if let limit = LimitNotice(refusal: refusal) {
                return .refused("\(limit.message) \(limit.detail)")
            }
            return .refused(refusal.message)
        } catch {
            return .refused("runbloom.app could not be reached. \(error.localizedDescription)")
        }
    }

    func openPreview() async {
        switch await previewEntry() {
        case .address(let url):
            NSWorkspace.shared.open(url)
        case .refused(let message):
            notice = CloudRefusalNotice(message: message, code: nil)
        }
    }
}
