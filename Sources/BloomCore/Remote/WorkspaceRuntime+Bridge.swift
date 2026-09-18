import Foundation

// The agent bridge inside a Cloud workspace: the socket an agent calls back in through, the tools
// it is offered, and the crew those tools run.
//
// **Only the tools that are about this one workspace.** A machine holds one worktree and nothing
// else, so `workspace_start`, `workspace_say` and the other cross-workspace tools have nothing to
// reach, and the browser, pane and terminal pane tools are about a window this machine does not
// have. What is left is who am I, the chats beside me, the diff I am making, and a crew. See the
// step 3 table in docs/REMOTE-WORKSPACES.md.
//
// **The crew runs through the queue, never around it.** On the Mac a crew member's brief, a
// message and a report are enqueued and then drained by the transcript; here the runtime's
// `RemotePromptQueue` is the drain, so every one of them waits behind a running turn exactly as a
// person's prompt does, and none is registered with runbloom.app because none is a person's turn.
extension WorkspaceRuntime {
    // MARK: - The socket

    /// Starts listening when a socket path was given. Called first thing in `start()`, so a session
    /// the queue restores is launched with its tools.
    func startBridge() throws {
        guard bridge == nil, let bridgeSocketPath else { return }
        let server = BridgeServer(store: store, socketPath: bridgeSocketPath, toolbox: bridgeToolbox())
        try server.start()
        bridge = server
    }

    func stopBridge() {
        bridge?.stop()
        bridge = nil
    }

    /// `BridgeServer.register(session:workspace:)`, with the shim named rather than found.
    ///
    /// That method finds `bloom-bridge` beside the running executable, which is right for the app
    /// bundle and for the machine, where the two binaries are installed side by side, and cannot
    /// be pointed anywhere in a test, whose executable is the test runner. The rest is the same
    /// two cases in the same order: a JSON file for Claude Code, the attachment alone for the two
    /// backends that take it inline. A config that cannot be written leaves the chat with no
    /// bridge rather than refusing to start it, for the reason the original gives.
    nonisolated static func registerBridge(
        _ server: BridgeServer, shimPath: String?, session: Session, workspace: Workspace
    ) -> BridgeHandle? {
        guard let shimPath else { return nil }
        let attachment = server.attach(session: session, workspace: workspace, shimPath: shimPath)
        switch session.agentKind {
        case .codex, .grok:
            return BridgeHandle(attachment: attachment, mcpConfigPath: nil)
        case .claudeCode, .cursor, .openCode:
            guard let path = try? BridgeRegistration.writeClaudeConfig(
                attachment, sessionID: session.id, directory: server.configDirectory
            ) else { return nil }
            server.sweepConfigDirectory()
            return BridgeHandle(attachment: attachment, mcpConfigPath: path)
        }
    }

    // MARK: - The tools

    /// Every tool an agent on this machine is offered, each held to this workspace.
    ///
    /// Weak back to the runtime, because the server holding this toolbox is the runtime's own and
    /// a strong capture would keep both alive for ever.
    nonisolated func bridgeToolbox() -> BridgeToolbox {
        let handlers: [any BridgeToolHandling] = [
            WhoamiTool(environment: briefing),
            ChatListTool(),
            ChatReadTool(),
            WorkspaceDiffTool(),
            AgentListTool(),
            CloudSetupTool(),
            AgentStartTool { [weak self] order, sessionID, workspaceID in
                guard let self else { return .refused(RemoteFailure.shuttingDown.message) }
                return await self.startCrewMember(order, parentID: sessionID, workspaceID: workspaceID)
            },
            AgentSayTool { [weak self] name, text, sessionID, workspaceID in
                guard let self else { return .refused(RemoteFailure.shuttingDown.message) }
                return await self.sayToCrew(name, text: text, callerID: sessionID, workspaceID: workspaceID)
            },
            RequestPaneTool { [weak self] url, sessionID, _ in
                guard let self else { return 0 }
                return await self.requestPane(url: url, chatID: sessionID)
            },
            AgentStopTool { [weak self] name, sessionID, workspaceID in
                guard let self else { return .refused(RemoteFailure.shuttingDown.message) }
                return await self.stopCrewMember(name, callerID: sessionID, workspaceID: workspaceID)
            },
        ]
        return BridgeToolbox(
            handlers: handlers.map { WorkspaceScopedTool(wrapped: $0, workspaceID: workspaceID) },
            briefing: briefing
        )
    }

    /// `request_pane`: hands an agent's request to every client that is listening, and answers how
    /// many that was.
    ///
    /// **Zero is the answer that matters.** A machine runs with every window shut, and an agent
    /// that was told it had shown somebody something would go on to say so. Counting the
    /// subscribers rather than assuming is the whole honesty of the tool.
    func requestPane(url: String?, chatID: SessionID?) async -> Int {
        let listening = await events.count
        guard listening > 0 else { return 0 }
        await events.publish(.paneRequested(url: url, chatID: chatID?.rawValue))
        return listening
    }

    // MARK: - The crew

    /// `agent_start`: a new chat under the caller, on the caller's agent, with its brief queued.
    ///
    /// The tool has already weighed the name and the ceiling against the rows; the nesting rule is
    /// checked again here because this is a second door into the same act, as
    /// `WorkspaceModel.startCrewMember` argues on the Mac.
    func startCrewMember(_ order: CrewOrder, parentID: SessionID, workspaceID: WorkspaceID) async -> CrewStartOutcome {
        do {
            let permit = try admissions.admit()
            defer { permit.release() }
            try requireThisWorkspace(workspaceID)
            guard !isClosed, !closingSessions.contains(parentID) else { throw RemoteFailure.shuttingDown }
            let parent = try await storedSession(parentID)
            guard parent.archivedAt == nil else {
                throw RemoteFailure(.unavailable, "The chat that asked for this subagent has been closed.")
            }
            guard parent.parentSessionID == nil else { return .refused(Crew.sentence(for: .notAnOrchestrator)) }
            guard let name = Crew.normalisedName(order.name) else { return .refused(Crew.sentence(for: .noName)) }
            try await requireInstalled(parent.agentKind)
            _ = try await workspace()
            let siblings = try await store.sessions(workspaceID: workspaceID)
            // `upsert`, because the row is being created out of a value built here and now.
            let member = try await store.upsert(Session(
                workspaceID: workspaceID, parentSessionID: parentID, title: name,
                model: order.model ?? parent.model, effort: order.effort ?? parent.effort,
                agentKind: parent.agentKind, permissionMode: parent.permissionMode, sortOrder: siblings.count
            ))
            try await queue().enqueue(Delivery(
                targetSessionID: member.id, sourceWorkspaceID: workspaceID, kind: .message,
                crew: CrewMessage.brief(from: parent.title, task: order.task)
            ))
            return .started(
                "Started subagent \"\(name)\" in this workspace. Talk to it with agent_say, and Bloom "
                    + "will tell you here when it stops, with the last thing it said."
            )
        } catch {
            return .refused(error.localizedDescription)
        }
    }

    /// `agent_say`, down to a named crew member or, with no name, up to the chat that started the
    /// caller. Both are wrapped as another agent's words by `CrewMessage.said`.
    func sayToCrew(_ name: String?, text: String, callerID: SessionID, workspaceID: WorkspaceID) async -> CrewSayOutcome {
        do {
            let permit = try admissions.admit()
            defer { permit.release() }
            try requireThisWorkspace(workspaceID)
            let caller = try await storedSession(callerID)
            let target: Session
            let message: CrewMessage
            if let name {
                target = try await crewMember(named: name, of: callerID, tool: CrewToolName.say)
                message = CrewMessage.said(from: caller.title, text: text, sender: .orchestrator)
            } else {
                guard let parentID = caller.parentSessionID else {
                    return .refused(
                        "No agent started this chat, so there is nobody above it to talk to. Name the "
                            + "subagent you meant to say that to."
                    )
                }
                target = try await storedSession(parentID)
                message = CrewMessage.said(from: caller.title, text: text, sender: .subagent)
            }
            // A closed chat is refused rather than woken: a turn in a conversation nobody has open
            // is an agent nobody can see, spending money.
            guard target.archivedAt == nil, !closingSessions.contains(target.id) else {
                return .refused(name == nil
                    ? "The chat that started you has been closed, so there is nobody above you to talk to any more. Finish what you can on your own and stop."
                    : "That subagent's chat has been closed. Start a new one instead.")
            }
            try await queue().enqueue(Delivery(
                targetSessionID: target.id, sourceWorkspaceID: workspaceID, kind: .message, crew: message
            ))
            // Never read mid turn here, whatever the backend could do: the queue holds every
            // message behind a running turn, so the sentence says that rather than `Crew`'s.
            let when = "If it is mid turn it will read this when that turn ends."
            if name == nil { return .delivered("Passed that to the agent that started you. \(when)") }
            return .delivered("Passed that to subagent \"\(target.title)\". \(when) Bloom will tell you here when it stops.")
        } catch {
            return .refused(error.localizedDescription)
        }
    }

    /// `agent_stop`: the member's chat is closed, its transcript kept, and its parent is not told,
    /// because the parent is the one asking.
    func stopCrewMember(_ name: String, callerID: SessionID, workspaceID: WorkspaceID) async -> CrewStopOutcome {
        do {
            let permit = try admissions.admit()
            defer { permit.release() }
            try requireThisWorkspace(workspaceID)
            let member = try await crewMember(named: name, of: callerID, tool: CrewToolName.stop)
            try await closeChat(member.id, notifyingParent: false)
            return .stopped(
                "Stopped subagent \"\(member.title)\" and closed its chat. Its conversation is still "
                    + "here to read, and the name is free to use again."
            )
        } catch {
            return .refused(error.localizedDescription)
        }
    }

    /// Called from `closeChat` once the chat's turn is stopped and before its agent goes.
    ///
    /// The token is retired so the config file is a dead letter. A crew member closed by a person
    /// rather than by its parent tells the parent, because an orchestrator waiting on a member it
    /// can no longer reach looks exactly like one waiting on a member still thinking.
    func crewChatClosing(_ session: Session, notifyingParent: Bool) async {
        bridge?.retire(sessionID: session.id)
        guard notifyingParent, let parent = await openParent(of: session) else { return }
        try? await queue().enqueue(Delivery(
            targetSessionID: parent.id, sourceWorkspaceID: workspaceID, kind: .report,
            crew: CrewMessage.stoppedByOwner(name: session.title)
        ))
    }

    /// Queues a crew member's report to its parent when its turn comes to rest.
    ///
    /// **Not when another turn is about to start.** A turn that finished with a message already
    /// waiting behind it, such as its orchestrator saying something mid turn, goes straight into
    /// that next turn, and reporting a stop in the same breath would have the orchestrator act on
    /// an answer about to be superseded. The Mac makes the same call by reporting only when the
    /// drain left the chat idle. A failure or a stop pauses this queue, so those always report.
    func reportToParent(_ id: SessionID, ending: RemoteTurnEnd) async {
        guard !isClosed, !closingSessions.contains(id),
              let member = try? await store.session(id: id), member.workspaceID == workspaceID, member.archivedAt == nil,
              let parent = await openParent(of: member) else { return }
        let report: CrewMessage
        switch ending {
        case .completed(let summary):
            let waiting = (try? await store.pendingDeliveries(sessionID: id)) ?? []
            guard !waiting.contains(where: { $0.state == .pending }) else { return }
            report = CrewMessage.stopped(name: member.title, lastMessage: summary)
        case .stopped(let summary):
            report = CrewMessage.stopped(name: member.title, lastMessage: summary)
        case .failed(let reason):
            report = CrewMessage.failed(name: member.title, reason: reason)
        }
        try? await queue().enqueue(Delivery(
            targetSessionID: parent.id, sourceWorkspaceID: workspaceID, kind: .report, crew: report
        ))
    }

    // MARK: - Shared

    private func openParent(of session: Session) async -> Session? {
        guard let parentID = session.parentSessionID,
              let parent = try? await store.session(id: parentID),
              parent.workspaceID == workspaceID, parent.archivedAt == nil,
              !closingSessions.contains(parentID) else { return nil }
        return parent
    }

    /// Refuses a call speaking for another workspace. The scoped toolbox already does, so this is
    /// the second lock on a closure that could be reached some other way one day.
    private func requireThisWorkspace(_ id: WorkspaceID) throws {
        guard id == workspaceID else { throw RemoteFailure.notFound(WorkspaceScopedTool.elsewhere) }
    }

    /// Read again rather than trusted from the tool, which resolved the name a hop earlier.
    private func crewMember(named name: String, of callerID: SessionID, tool: String) async throws -> Session {
        let crew = try await store.crew(of: callerID)
        switch CrewLookup.find(name, among: crew) {
        case .found(let member) where member.workspaceID == workspaceID:
            return member
        case .found, .unknown:
            throw RemoteFailure.notFound(CrewToolTrouble.unknownMember(tool: tool, given: name, known: crew.map(\.title)).sentence)
        case .ambiguous:
            throw RemoteFailure.invalid(CrewToolTrouble.ambiguousMember(tool: tool, given: name).sentence)
        }
    }
}

/// A tool held to the one workspace on this machine and to agents working in it.
///
/// The owner's role is not offered anything. `BridgeServer` admits a standalone owner token from
/// beside the database whether or not anybody wants one, and on a machine there is no owner's own
/// terminal for it to serve, so every tool answers `.workspace` alone. A token minted for another
/// workspace cannot exist here, since the runtime registers only its own chats, and is refused all
/// the same so the rule does not rest on that.
private struct WorkspaceScopedTool: BridgeToolHandling {
    static let elsewhere = "This Cloud workspace's bridge only answers agents working in it."

    let wrapped: any BridgeToolHandling
    let workspaceID: WorkspaceID

    var tool: BridgeTool { wrapped.tool }
    var roles: Set<BridgeRole> { wrapped.roles.intersection([.workspace]) }

    func call(_ request: MCPRequest, as identity: BridgeIdentity, store: Store) async -> BridgeToolResult {
        guard identity.role == .workspace, identity.workspaceID == workspaceID else { return .failure(Self.elsewhere) }
        return await wrapped.call(request, as: identity, store: store)
    }
}
