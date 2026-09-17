import BloomProtocol
import Foundation

/// The connection to one open Cloud workspace: its session token, its commands and its event
/// stream, and the whole of the client chapter's rules about keeping them alive.
///
/// **What it owns:** fetching a session token from runbloom.app and replacing it before it runs out,
/// both for commands and for the open stream; retrying a command that got no answer under the
/// command id it was first sent with; reconnecting a stream that dropped, from the cursor it had
/// reached; and not reconnecting after `sleeping`, because a reconnect is what wakes the machine and
/// only a person doing something should do that.
///
/// **What it does not own:** the workspace's state. It reports what it reads through `updates`
/// and the caller folds that into a `CloudWorkspaceState`, because the caller is the one drawing it.
public actor WorkspaceConnection {
    /// Where the connection is, as a person would be told.
    public enum Phase: Sendable, Hashable {
        /// Not opened, or closed on purpose.
        case closed
        /// Opening. `waking` turns true after half a second for a machine last seen asleep, so the
        /// window says it is waking rather than showing a spinner with no words.
        case connecting(waking: Bool)
        /// The stream is open.
        case live
        /// The machine went to sleep. Nothing reconnects until somebody does something.
        case asleep
        /// runbloom.app has no machine to hand out yet: still being created, or being replaced.
        /// Retried after `retryAfter` seconds.
        case notReady(message: String, retryAfter: Int)
        /// A team limit refused the wake. Retried by itself only when the limit clears by itself.
        case limited(LimitNotice)
        /// The workspace was archived.
        case archived
        /// Access went away, or the account is signed out. Never retried.
        case noAccess(String)
        /// The machine did not answer and the connection is trying again.
        case retrying(String)

        public var isConnecting: Bool {
            if case .connecting = self { true } else { false }
        }
    }

    public enum Update: Sendable, Hashable {
        case phase(Phase)
        /// The `workspace` read that every connection starts with.
        case snapshot(WorkspaceSnapshotRecord)
        case event(WorkspaceEvent)
        /// A frame this client could not decode; only its cursor matters.
        case skipped(cursor: Int64?)
    }

    /// A command that did not produce a result.
    public enum CommandFailure: Error, Sendable, Hashable {
        /// The machine answered with a refusal.
        case refused(WireError)
        /// runbloom.app would not hand out a token.
        case runbloom(RunbloomRefusal)
        /// No answer, even after retrying under the same command id. Whether it ran is unknown.
        case noAnswer(String)
        case unreadable(String)

        public var message: String {
            switch self {
            case .refused(let error): error.message
            case .runbloom(let refusal): refusal.message
            case .noAnswer(let detail), .unreadable(let detail): detail
            }
        }

        public var code: WireErrorCode? {
            if case .refused(let error) = self { error.knownCode } else { nil }
        }
    }

    public nonisolated let workspaceID: String
    public nonisolated let updates: AsyncStream<Update>

    private let api: RunbloomAPI
    private let machine: MachineClient
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let continuation: AsyncStream<Update>.Continuation

    private var token: SessionToken?
    private var tokenTask: Task<SessionToken, any Error>?
    private var streamTask: Task<Void, Never>?
    private var cursor: Int64?
    private var phase: Phase = .closed
    /// Set once a request has been answered since the last time the machine was known to sleep, so
    /// only the first request after a pause is given the long allowance.
    private var hasBeenAnswered = false
    /// Streams refused with a fresh token, in a row. One fresh token is worth trying; a second
    /// refusal means access went away.
    private var refusedStreams = 0

    public init(
        workspaceID: String, api: RunbloomAPI, machine: MachineClient = MachineClient(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.workspaceID = workspaceID
        self.api = api
        self.machine = machine
        self.now = now
        self.sleep = sleep
        (updates, continuation) = AsyncStream.makeStream(of: Update.self, bufferingPolicy: .unbounded)
    }

    /// The first request to a sleeping machine is what wakes it, and the first one after a pause
    /// measured 4.5 s end to end, so it gets far more than ten seconds before it counts as no answer.
    static let wakingTimeout: TimeInterval = 45
    static let awakeTimeout: TimeInterval = 25
    /// How long a machine last seen asleep may take before the window says it is waking.
    static let wakingNotice: Duration = .milliseconds(500)
    static let commandAttempts = 3

    public var currentPhase: Phase { phase }

    /// The abilities the current token carries, or none before one has been fetched.
    public var abilities: [String] { token?.abilities ?? [] }

    /// The machine's address, once a token named it.
    public var machineURL: URL? { token?.machineURL }

    // MARK: Opening and closing

    /// Opens the event stream, unless it is open or opening already.
    public func open() {
        guard streamTask == nil else { return }
        streamTask = Task { await self.run() }
    }

    /// Opens again after the machine slept, or after a limit or a failure a person chose to retry.
    public func resume() {
        switch phase {
        case .live, .connecting, .retrying, .notReady: return
        default: break
        }
        streamTask?.cancel()
        streamTask = nil
        open()
    }

    /// Closes the stream but keeps what the connection knows (its cursor, its token), so opening it
    /// again resumes exactly where it stopped. For a workspace nobody is looking at: a stream left
    /// open would reconnect by itself after a dropped network, and a reconnect wakes the machine.
    public func suspend() {
        streamTask?.cancel()
        streamTask = nil
        set(.closed)
    }

    public func close() {
        streamTask?.cancel()
        streamTask = nil
        tokenTask?.cancel()
        tokenTask = nil
        set(.closed)
        continuation.finish()
    }

    // MARK: Commands

    /// Sends one command and answers its result.
    ///
    /// **The command id is decided by the caller and kept.** A mutation the caller wants to be able
    /// to retry after this returns (because the window was closed, say) is sent again with the id
    /// it was first given. Inside this call, a request that got no answer is retried with the same
    /// id, which the machine answers from its record if it had run it.
    public func perform(_ operation: WorkspaceOperation, commandID: String = UUID().uuidString.lowercased()) async throws(CommandFailure) -> OperationResult {
        let command = CommandRequest(operation, commandID: commandID)
        if case .asleep = phase { resume() }
        var lastProblem = "It did not answer."
        var refreshed = false
        var attempt = 0
        while attempt < Self.commandAttempts {
            attempt += 1
            let session: SessionToken
            do {
                session = try await currentToken(forceRefresh: false)
            } catch let refusal as RunbloomRefusal {
                throw .runbloom(refusal)
            } catch {
                throw .noAnswer(MachineClient.describe(error))
            }
            let timeout = hasBeenAnswered ? Self.awakeTimeout : Self.wakingTimeout
            let answer: Result<CommandReply, MachineFailure>
            do {
                answer = .success(try await machine.send(command, to: session.machineURL, token: session.token, timeout: timeout + extraWait(for: operation)))
            } catch {
                answer = .failure(error)
            }
            switch answer {
            case .success(let reply):
                hasBeenAnswered = true
                if let error = reply.error { throw .refused(error) }
                guard let result = reply.result else { throw .unreadable("The reply carried neither a result nor an error.") }
                return result
            case .failure(.unauthenticated(let error)):
                // One fresh token, then the refusal stands: access went away.
                guard !refreshed else { throw .refused(error) }
                refreshed = true
                attempt -= 1
                token = nil
            case .failure(.noAnswer(let detail)):
                lastProblem = detail
                hasBeenAnswered = false
                if attempt < Self.commandAttempts { try? await sleep(.seconds(attempt)) }
            case .failure(.refused(_, let error)):
                throw .refused(error)
            case .failure(.unreadable(let detail)):
                throw .unreadable(detail)
            }
        }
        throw .noAnswer("The Cloud workspace did not answer. \(lastProblem)")
    }

    /// A long poll waits on the machine before answering, so it gets that long on top.
    private func extraWait(for operation: WorkspaceOperation) -> TimeInterval {
        if case .reviewSnapshot(_, _, true) = operation { 20 } else { 0 }
    }

    // MARK: Tokens

    /// The current token, fetched or replaced when it is within a minute of running out. One fetch
    /// at a time: callers arriving during a fetch wait for the same one.
    public func currentToken(forceRefresh: Bool) async throws -> SessionToken {
        if !forceRefresh, let token, !token.needsRefresh(at: now()) { return token }
        if let tokenTask { return try await tokenTask.value }
        let task = Task { [api, workspaceID] in try await api.sessionToken(for: workspaceID) }
        tokenTask = task
        defer { tokenTask = nil }
        let fresh = try await task.value
        guard fresh.hasSafeMachineURL else { throw SessionToken.unsafeMachineURL }
        token = fresh
        return fresh
    }

    // MARK: The stream

    private func run() async {
        var failures = 0
        refusedStreams = 0
        while !Task.isCancelled {
            let outcome = await connectOnce()
            if Task.isCancelled { return }
            switch outcome {
            case .stop:
                streamTask = nil
                return
            case .reconnectNow:
                failures = 0
            case .retry(let delay):
                failures += 1
                let wait = delay ?? Double(min(30, 1 << min(failures, 5)))
                try? await sleep(.seconds(wait))
            }
        }
    }

    private enum Outcome {
        case stop
        case reconnectNow
        case retry(after: Double?)
    }

    private func connectOnce() async -> Outcome {
        if case .retrying = phase {} else { set(.connecting(waking: false)) }
        let notice = Task { [sleep] in
            try await sleep(Self.wakingNotice)
            self.noticeWaking()
        }
        defer { notice.cancel() }

        let session: SessionToken
        do {
            session = try await currentToken(forceRefresh: token == nil ? false : token!.needsRefresh(at: now()))
        } catch let refusal as RunbloomRefusal {
            return outcome(for: refusal)
        } catch {
            set(.retrying(MachineClient.describe(error)))
            return .retry(after: nil)
        }

        // The `workspace` read first, then the stream from its cursor, when this is the first
        // connection. A reconnect already has a cursor and needs only the stream, whose state
        // events arrive whole.
        if cursor == nil {
            do {
                let result = try await perform(.workspace)
                guard case .workspace(let snapshot) = result else {
                    set(.retrying("The Cloud workspace answered with something other than itself."))
                    return .retry(after: nil)
                }
                advance(snapshot.cursor)
                continuation.yield(.snapshot(snapshot))
            } catch {
                return outcome(for: error)
            }
        }

        let opened: (streamID: String?, events: AsyncThrowingStream<MachineClient.StreamItem, any Error>)
        do {
            opened = try await machine.events(from: session.machineURL, token: session.token, after: cursor, timeout: Self.wakingTimeout)
        } catch {
            switch error {
            case .unauthenticated(let wire):
                refusedStreams += 1
                guard refusedStreams < 2 else {
                    set(.noAccess(wire.message))
                    return .stop
                }
                token = nil
                return .retry(after: 1)
            case .noAnswer(let detail), .unreadable(let detail):
                set(.retrying(detail))
                return .retry(after: nil)
            case .refused(_, let wire):
                set(.retrying(wire.message))
                return .retry(after: nil)
            }
        }
        notice.cancel()
        hasBeenAnswered = true
        refusedStreams = 0
        set(.live)

        let refresher = opened.streamID.map { id in
            Task { await self.keepFresh(stream: id, machineURL: session.machineURL) }
        }
        defer { refresher?.cancel() }

        do {
            for try await item in opened.events {
                switch item {
                case .skipped(let skipped):
                    if let skipped { advance(skipped) }
                    continuation.yield(.skipped(cursor: skipped))
                case .event(let event):
                    if let value = event.cursor { advance(value) }
                    continuation.yield(.event(event))
                    switch event {
                    case .sleeping:
                        hasBeenAnswered = false
                        token = nil
                        set(.asleep)
                        return .stop
                    case .closing(let error):
                        switch error.knownCode {
                        case .tokenExpired:
                            token = nil
                            return .reconnectNow
                        case .unauthenticated:
                            set(.noAccess(error.message))
                            return .stop
                        default:
                            set(.retrying(error.message))
                            return .retry(after: nil)
                        }
                    default:
                        break
                    }
                }
            }
        } catch {
            if Task.isCancelled { return .stop }
            set(.retrying(MachineClient.describe(error)))
            return .retry(after: nil)
        }
        if Task.isCancelled { return .stop }
        // The server closed the stream without saying why: a restart, most likely. Backed off like
        // any other failure, so a server that closes every stream at once is not asked every second.
        set(.retrying("The connection closed."))
        return .retry(after: nil)
    }

    /// Half a second in and still not live. A machine runbloom.app last saw asleep, or one not yet
    /// asked about, is waking; one it saw awake is only slow, and says nothing new.
    private func noticeWaking() {
        guard case .connecting = phase else { return }
        set(.connecting(waking: !(token?.awake ?? false)))
    }

    /// Sends the stream a fresh token a minute before the current one runs out, for as long as it
    /// is open.
    private func keepFresh(stream id: String, machineURL: URL) async {
        while !Task.isCancelled {
            let expiry = token?.expiresAt ?? now().addingTimeInterval(240)
            let wait = max(5, expiry.timeIntervalSince(now()) - 70)
            try? await sleep(.seconds(wait))
            if Task.isCancelled { return }
            guard let fresh = try? await currentToken(forceRefresh: true) else { continue }
            _ = await machine.refresh(stream: id, on: fresh.machineURL, token: fresh.token)
        }
    }

    private func outcome(for error: any Error) -> Outcome {
        if let refusal = error as? RunbloomRefusal { return outcome(for: refusal) }
        if let failure = error as? CommandFailure {
            switch failure {
            case .runbloom(let refusal): return outcome(for: refusal)
            case .refused(let wire) where wire.knownCode == .unauthenticated:
                set(.noAccess(wire.message))
                return .stop
            case .refused(let wire):
                set(.retrying(wire.message))
                return .retry(after: nil)
            case .noAnswer(let detail), .unreadable(let detail):
                set(.retrying(detail))
                return .retry(after: nil)
            }
        }
        set(.retrying(error.localizedDescription))
        return .retry(after: nil)
    }

    private func outcome(for refusal: RunbloomRefusal) -> Outcome {
        if refusal.isMachineNotReady || refusal.isSharingInProgress {
            let wait = max(2, refusal.retryAfter ?? 5)
            set(.notReady(message: refusal.message, retryAfter: wait))
            return .retry(after: Double(wait))
        }
        if refusal.isArchived {
            set(.archived)
            return .stop
        }
        if let notice = LimitNotice(refusal: refusal) {
            set(.limited(notice))
            if notice.kind == .waiting { return .retry(after: Double(max(15, refusal.retryAfter ?? 60))) }
            return .stop
        }
        if refusal.isUnauthenticated || refusal.status == 403 || refusal.status == 404 {
            set(.noAccess(refusal.message))
            return .stop
        }
        set(.retrying(refusal.message))
        return .retry(after: nil)
    }

    private func advance(_ value: Int64) {
        if cursor.map({ value > $0 }) ?? true { cursor = value }
    }

    private func set(_ new: Phase) {
        guard new != phase else { return }
        phase = new
        continuation.yield(.phase(new))
    }
}
