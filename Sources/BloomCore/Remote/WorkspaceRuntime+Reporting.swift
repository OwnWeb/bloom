import BloomProtocol
import Foundation

/// Something the machine's server needs to hear about as it happens: to take or let go of its
/// hold on the machine, to record usage, and to post a summary.
public enum RemoteActivityEvent: Sendable, Hashable {
    case turnStarted(chat: SessionID, turnID: String?, author: MessageAuthor?, agent: AgentKind)
    case turnFinished(chat: SessionID)
    case setupStarted(step: String)
    case setupStep(String)
    case setupFinished(succeeded: Bool)
    case humanInput
    case connectionsChanged(open: Int)
}

/// What the awake policy asks of the runtime.
public struct RemoteActivity: Sendable, Hashable {
    public var setupRunning: Bool
    public var turnsRunning: Int
    public var questionWaitingSince: Date?
    public var lastHumanInputAt: Date?
    public var openStreams: Int
}

// The runtime as the machine's reports see it: what is running, what the summary says, and who is
// told when either changes.
extension WorkspaceRuntime {
    /// The runbloom.app turn a chat is running, which is whose GitHub token a push from that
    /// chat's agent uses.
    public func runningTurnID(chat: String) async -> String? {
        guard !chat.isEmpty else { return nil }
        return await promptQueue?.runningTurn(SessionID(chat))
    }

    public func observeActivity(_ observer: @escaping @Sendable (RemoteActivityEvent) async -> Void) {
        activityObserver = observer
    }

    func report(_ event: RemoteActivityEvent) async {
        await activityObserver?(event)
    }

    public func activity() async -> RemoteActivity {
        var running = 0
        var waitingSince: Date?
        for (id, session) in sessions where await session.isBusy {
            running += 1
            if let asked = try? await store.pendingPermissionAsks(sessionID: id).map(\.askedAt).min() {
                waitingSince = min(waitingSince ?? asked, asked)
            }
        }
        // A turn waiting on a question only counts as waiting when every running turn is.
        let everyTurnWaiting = running > 0 && waitingSince != nil
        return RemoteActivity(
            setupRunning: holdsPromptsForSetup, turnsRunning: running,
            questionWaitingSince: everyTurnWaiting ? waitingSince : nil,
            lastHumanInputAt: presence.lastHumanInputAt, openStreams: await events.count
        )
    }

    /// The summary as it stands. Revision, time, version, awake and the lease are the server's to
    /// supply; the diff and pull request are measured on their own, slower, schedule.
    public func summary(
        revision: Int64, observedAt: Date, version: String, awake: Bool, leaseUntil: Date?,
        diff: RemoteSummary.Diff, pullRequest: RemoteSummary.PullRequest?
    ) async throws -> RemoteSummary {
        let workspace = try await workspace()
        var chats: [RemoteSummary.Chat] = []
        var activities: [RemoteSummary.ChatActivity] = []
        var waiting: RemoteSummary.Waiting?
        var runningSince: Date?
        for session in try await store.sessions(workspaceID: workspaceID) where session.archivedAt == nil {
            let live = sessions[session.id]
            let questions = try await store.pendingPermissionAsks(sessionID: session.id)
            let queued = try await store.pendingDeliveries(sessionID: session.id)
            var activity = RemoteSummary.ChatActivity(
                busy: await live?.isBusy ?? false, blocked: queued.contains { $0.block != nil },
                stopping: stopping[session.id] != nil
            )
            if let first = questions.min(by: { $0.askedAt < $1.askedAt }) {
                activity.waitingSince = first.askedAt
                activity.waitingKind = first.ask.isPlanApproval ? "plan" : (first.ask.isQuestion ? "question" : "permission")
                if waiting.map({ first.askedAt < $0.since }) ?? true {
                    waiting = RemoteSummary.Waiting(kind: activity.waitingKind ?? "permission", chatID: session.id.rawValue, since: first.askedAt)
                }
            }
            if let since = await live?.busySince { runningSince = min(runningSince ?? since, since) }
            activities.append(activity)
            chats.append(RemoteSummary.Chat(id: session.id.rawValue, title: session.title, agent: session.agentKind.wireName, state: activity.state))
        }
        let last = try await store.lastMessage(workspaceID: workspaceID, kinds: [.assistantText, .user, .crew])
        return RemoteSummary(
            revision: revision, observedAt: observedAt, bloomServerVersion: version, title: workspace.name,
            branch: workspace.branch, baseBranch: workspace.baseBranch,
            state: RemoteSummary.state(setup: workspace.setupState, chats: activities), awake: awake,
            presenceLeaseUntil: leaseUntil,
            setup: RemoteSummary.Setup(state: workspace.setupState.rawValue, step: setupStep, startedAt: setupStartedAt, finishedAt: setupFinishedAt),
            lastMessage: last.map { message in
                RemoteSummary.LastMessage(
                    chatID: message.sessionID.rawValue, authorKind: message.kind == .assistantText ? "agent" : "user",
                    authorUserID: message.author?.userID, excerpt: Self.excerpt(ChatTranscriptPage.content(of: message)), at: message.createdAt
                )
            },
            waiting: waiting, runningSince: runningSince, diff: diff, pullRequest: pullRequest, chats: chats,
            presentUserIDs: presence.connected.sorted()
        )
    }

    /// A line or two a list can show: whitespace collapsed, and cut at a word near 200 characters.
    static func excerpt(_ text: String, limit: Int = 200) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        let cut = collapsed.prefix(limit)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return atWord + "…"
    }
}
