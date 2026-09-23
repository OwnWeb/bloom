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
        /// runbloom.app has no machine to hand out: being created, bootstrapped, replaced or
        /// deleted, or one whose build failed. Retried after `retryAfter` seconds.
        ///
        /// **Never a sleeping machine.** The refusal behind this asks whether the machine's state
        /// is ready, which is nothing to do with whether it is awake: a machine that is asleep and
        /// ready gets a token and is woken by the first request made with it. So nothing drawn for
        /// this phase may say "waking", and the sentence shown is runbloom.app's own, because it
        /// knows which of those five it is and this does not. `detail` is why the wait is long,
        /// when runbloom.app knows, for the setup card to draw under the step. See
        /// `RunbloomRefusal.detail`.
        case notReady(message: String, retryAfter: Int, detail: String? = nil)
        /// A team limit refused the wake. Retried by itself only when the limit clears by itself.
        case limited(LimitNotice)
        /// The workspace was archived.
        case archived
        /// Access went away, or the account is signed out. Never retried.
        case noAccess(String)
        /// runbloom.app answered, and its answer was an end: a machine whose build failed, one that
        /// is being deleted or already gone, or anything else it refuses without a retry hint.
        ///
        /// **Told apart by the hint rather than by a list of codes.** runbloom.app sends
        /// `retry_after` on the refusals where asking again can change the answer and leaves it off
        /// where it cannot, so a terminal code added later needs nothing here. The sentence is
        /// runbloom.app's own, because it knows which of its machine states this is and this does
        /// not; grouping its states here is how two clients come to group them differently.
        case unavailable(String)
        /// The machine did not answer and the connection is trying again.
        case retrying(String)
        /// Asked to wake and still not answering, long enough that "a few seconds" has stopped
        /// being true. Still being retried: this is a sentence rather than a stop.
        ///
        /// **What wakes a machine is the request itself.** runbloom.app reserves a slot against the
        /// awake limit and calls nothing: a paused machine answers in a fraction of a second and
        /// answering is waking. So a client that has a token and is waiting for something else to
        /// happen waits for ever, and this phase exists because the window was saying "this usually
        /// takes a few seconds" over a machine that had been asked and had not come back.
        case notWaking(since: Date)

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
        /// The caller no longer wants the command. Nothing should retry or be shown for it.
        case cancelled

        public var message: String {
            switch self {
            case .refused(let error): error.message
            case .runbloom(let refusal): refusal.message
            case .noAnswer(let detail), .unreadable(let detail): detail
            case .cancelled: "The command was cancelled."
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
    /// The sentence a wake that is taking too long is about to raise, held for `wakingGrace`. It
    /// outlives one attempt on purpose: a machine that has not woken is not woken by asking again.
    private var wakeNotice: Task<Void, Never>?
    /// The banner a dropped connection is about to raise, held for `retryingNotice`.
    private var retryNotice: Task<Void, Never>?
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

    /// How long "this usually takes a few seconds" stays true.
    ///
    /// A cap on a sentence rather than a measurement of a machine: the first request after a pause
    /// measured 4.5 seconds, so twenty is four times the ordinary case and still short enough that
    /// somebody watching has not yet decided the app is broken. After it, the banner says the
    /// workspace has not woken and offers the two things worth doing, and the connection carries on
    /// trying underneath.
    ///
    /// **Not a value from `retryDelays`.** It is a hold on a notice rather than a backoff, and the
    /// suite tells the two apart by the number: see `SleepLog.backoffSeconds`, which drops the
    /// notice holds by value because they race the loop that does the waiting.
    static let wakingGrace: Duration = .seconds(20)

    /// How long a connection that dropped may be gone before the window says so.
    ///
    /// **A machine's own runner restarts under an open window**: it updates itself the moment a
    /// sleeping workspace wakes and goes idle, which is seconds after somebody opens it, and the
    /// process is gone for about eight seconds on the good path. A banner on the instant the stream
    /// broke made that read as a workspace that had failed. Two seconds is two failed attempts, so
    /// a drop that mends itself says nothing at all, and one that does not is still named long
    /// before anybody could act on it.
    static let retryingNotice: Duration = .seconds(2)

    /// What a reconnection waits between attempts. The first four land inside seven seconds,
    /// which is what covers a runner restart, and it backs off to half a minute for a machine that
    /// is genuinely gone rather than asking a dead address every two seconds for an hour.
    static let retryDelays: [Double] = [0.5, 1, 2, 3, 5, 8, 13, 21, 30]

    /// How long a command keeps trying before it is a failure in front of a person.
    ///
    /// **Longer than the restart it has to survive.** Three attempts a second apart gave up after
    /// about five seconds, and the disappearance it most often meets lasts eight, so a prompt sent
    /// in that window was guaranteed to fail seconds before the machine came back. Retries go under
    /// one command id, so a machine that took the command before dying answers the retry from its
    /// journal rather than doing it twice.
    static let commandBudgetSeconds: TimeInterval = 30
    /// The fewest attempts a command gets, whatever the clock says, so a caller with an injected
    /// clock or a machine that fails instantly still retries rather than giving up on one refusal.
    static let commandAttempts = 3

    public var currentPhase: Phase { phase }

    /// The abilities the current token carries, or none before one has been fetched.
    public var abilities: [String] { token?.abilities ?? [] }

    /// The machine's address, once a token named it.
    public var machineURL: URL? { token?.machineURL }

    /// Who the current token was minted for, which is available as soon as one has been fetched
    /// and therefore before any account object exists. See `SessionToken.userID`.
    public var tokenUserID: String? { token?.userID }

    // MARK: Opening and closing

    /// Opens the event stream, unless it is open or opening already.
    public func open() {
        guard streamTask == nil else { return }
        streamTask = Task { await self.run() }
    }

    /// Opens again after the machine slept, or after a limit or a failure a person chose to retry.
    ///
    /// - Parameter announcing: whether this attempt is one somebody asked for, and so is news.
    ///
    /// **A press is not one of many, and that is the whole of why this parameter exists.**
    /// `connectOnce` deliberately keeps `retrying`, `notReady`, `limited` and `notWaking` across
    /// an attempt, because an automatic pass of the loop announcing itself made the banner appear
    /// and vanish every few seconds while nothing had changed. That rule is right about the loop
    /// and wrong about a person: a press is the only attempt in the sequence anybody is waiting
    /// on, so it says so, and the owner pressed Try Again on a machine that had not woken and
    /// watched nothing happen at all.
    ///
    /// Announcing is `connecting(waking: true)`, which is a banner that already exists, draws a
    /// spinner and carries no button, so the control that was pressed goes away while the attempt
    /// runs and comes back if it fails. No new state, no timer, and nothing to keep in step.
    ///
    /// **A phase that says a stream is running is believed only while one is.** This returned for
    /// `live`, `connecting`, `retrying` and `notReady` on the label alone, and a label can outlive
    /// the loop that wrote it: see `set(_:)` for the one that did. A connection whose phase said
    /// `live` with nothing behind it was deaf for good, because this and `perform` were the only
    /// two ways back and both believed the label.
    public func resume(announcing: Bool = false) {
        if streamTask != nil {
            switch phase {
            case .live, .connecting, .retrying, .notReady: return
            default: break
            }
        }
        streamTask?.cancel()
        streamTask = nil
        if announcing { force(.connecting(waking: true)) }
        open()
    }

    /// Closes the stream but keeps what the connection knows (its cursor, its token), so opening it
    /// again resumes exactly where it stopped. For a workspace nobody is looking at: a stream left
    /// open would reconnect by itself after a dropped network, and a reconnect wakes the machine.
    public func suspend() {
        streamTask?.cancel()
        streamTask = nil
        wakeNotice?.cancel()
        wakeNotice = nil
        force(.closed)
    }

    public func close() {
        streamTask?.cancel()
        streamTask = nil
        tokenTask?.cancel()
        tokenTask = nil
        wakeNotice?.cancel()
        wakeNotice = nil
        force(.closed)
        continuation.finish()
    }

    /// Puts the phase somewhere without a loop to have put it there, which is the state a lost
    /// loop used to leave behind. Internal, for the suite: see `aSendWhileNoStreamIsRunningOpensOne`.
    func setPhaseForTesting(_ new: Phase) { force(new) }

    /// Whether the phase tells a reader that events are arriving or about to, which is what makes
    /// a missing stream a fault rather than a choice. `closed` is somebody leaving the workspace,
    /// and the refusals and the limit are ends the loop reached on purpose, so none of those is
    /// reopened by a command going past.
    private var phaseExpectsStream: Bool {
        switch phase {
        case .live, .connecting, .retrying, .notReady, .notWaking: true
        default: false
        }
    }

    // MARK: Commands

    /// Sends one command and answers its result.
    ///
    /// **The command id is decided by the caller and kept.** A mutation the caller wants to be able
    /// to retry after this returns (because the window was closed, say) is sent again with the id
    /// it was first given. Inside this call, a request that got no answer is retried with the same
    /// id, which the machine answers from its record if it had run it.
    public func perform(_ operation: WorkspaceOperation, commandID: String = UUID().uuidString.lowercased()) async throws(CommandFailure) -> OperationResult {
        guard !Task.isCancelled else { throw .cancelled }
        let command = CommandRequest(operation, commandID: commandID)
        // A sleeping machine is woken by somebody doing something, and so is a stream that is not
        // there although the phase says it is. The second is the bug this was widened for: a Cloud
        // workspace sat on "Starting" under a message for minutes after its turn had ended, with
        // every send answered and no stream open since three quarters of an hour earlier, so the
        // turn's end was never heard. A person still sending is the plainest sign one is wanted.
        if case .asleep = phase {
            resume()
        } else if streamTask == nil, phaseExpectsStream {
            resume()
        }
        var lastProblem = "It did not answer."
        var refreshed = false
        var attempt = 0
        let deadline = now().addingTimeInterval(Self.commandBudgetSeconds)
        while attempt < Self.commandAttempts || now() < deadline {
            guard !Task.isCancelled else { throw .cancelled }
            attempt += 1
            let session: SessionToken
            do {
                session = try await currentToken(forceRefresh: false)
            } catch let refusal as RunbloomRefusal {
                throw .runbloom(refusal)
            } catch {
                guard !Task.isCancelled else { throw .cancelled }
                throw .noAnswer(MachineClient.describe(error))
            }
            let timeout = hasBeenAnswered ? Self.awakeTimeout : Self.wakingTimeout
            let answer: Result<CommandReply, MachineFailure>
            do {
                answer = .success(try await machine.send(command, to: session.machineURL, token: session.token, timeout: timeout + extraWait(for: operation)))
            } catch {
                guard !Task.isCancelled else { throw .cancelled }
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
                // Waited out rather than given up on, because the disappearance this most often
                // meets is a runner restarting itself, which lasts about eight seconds. The gap
                // grows and the whole thing stops at `commandBudget`.
                let wait = Self.retryDelays[min(attempt - 1, Self.retryDelays.count - 1)]
                guard now().addingTimeInterval(wait) < deadline else {
                    throw .noAnswer("The Bloom Cloud workspace did not answer. \(lastProblem)")
                }
                do {
                    try await sleep(.seconds(wait))
                } catch {
                    guard !Task.isCancelled else { throw .cancelled }
                    throw .noAnswer("The Bloom Cloud workspace did not answer. \(lastProblem)")
                }
            case .failure(.refused(_, let error)):
                throw .refused(error)
            case .failure(.unreadable(let detail)):
                throw .unreadable(detail)
            }
        }
        throw .noAnswer("The Bloom Cloud workspace did not answer. \(lastProblem)")
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
                let wait = delay ?? Self.retryDelays[min(failures, Self.retryDelays.count - 1)]
                failures += 1
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
        // **An attempt that is one of many does not announce itself as a new one.**
        //
        // This said `if case .retrying` and nothing else, so a machine that was still starting
        // went `notReady` -> `connecting` -> `notReady` on every pass of the loop, once every few
        // seconds for as long as it took. `connecting` draws no banner and `notReady` draws one,
        // so what the owner watched was the not-ready banner appearing and
        // vanishing while nothing about the machine had changed. A screen that changes its mind
        // reads as an app that does not know what is happening, which is worse than a slow one.
        //
        // Every phase that means "still trying, and here is why" survives the next attempt. What
        // is left to announce is a first connection, which is the only time `connecting` is news.
        switch phase {
        // `connecting` is in this list for the other half of the same rule: an attempt somebody
        // asked for has already announced itself in `resume(announcing:)`, and overwriting it here
        // with `waking: false` would take the banner away on the frame after they pressed.
        case .connecting, .retrying, .notReady, .limited, .notWaking: break
        default: set(.connecting(waking: false))
        }
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
            noticeRetrying(MachineClient.describe(error))
            return .retry(after: nil)
        }

        // The `workspace` read first, then the stream from its cursor, when this is the first
        // connection. A reconnect already has a cursor and needs only the stream, whose state
        // events arrive whole.
        if cursor == nil {
            do {
                let result = try await perform(.workspace)
                guard case .workspace(let snapshot) = result else {
                    noticeRetrying("The Bloom Cloud workspace answered with something other than itself.")
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
                noticeRetrying(detail)
                return .retry(after: nil)
            case .refused(_, let wire):
                noticeRetrying(wire.message)
                return .retry(after: nil)
            }
        }
        notice.cancel()
        retryNotice?.cancel()
        wakeNotice?.cancel()
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
                            noticeRetrying(error.message)
                            return .retry(after: nil)
                        }
                    default:
                        break
                    }
                }
            }
        } catch {
            if Task.isCancelled { return .stop }
            noticeRetrying(MachineClient.describe(error))
            return .retry(after: nil)
        }
        if Task.isCancelled { return .stop }
        // The server closed the stream without saying why: a restart, most likely. Backed off like
        // any other failure, so a server that closes every stream at once is not asked every second.
        noticeRetrying("The connection closed.")
        return .retry(after: nil)
    }

    /// Half a second in and still not live. A machine runbloom.app last saw asleep, or one not yet
    /// asked about, is waking; one it saw awake is only slow, and says nothing new.
    private func noticeWaking() {
        guard case .connecting = phase else { return }
        let waking = !(token?.awake ?? false)
        set(.connecting(waking: waking))
        guard waking else { return }
        wakeNotice?.cancel()
        wakeNotice = Task { [sleep] in
            try? await sleep(Self.wakingGrace)
            guard !Task.isCancelled else { return }
            self.noticeNotWaking()
        }
    }

    /// Half a minute of waking and still nothing. Said rather than waited out: see
    /// `Phase.notWaking`.
    private func noticeNotWaking() {
        guard case .connecting(waking: true) = phase else { return }
        set(.notWaking(since: now()))
    }

    /// Says the connection dropped, once it has been down long enough to be worth saying. A drop
    /// that mends inside `retryingNotice` says nothing at all: see the note there for the restart
    /// this exists for.
    private func noticeRetrying(_ message: String) {
        // A cancelled loop's failure is the cancellation, and replacing the current notice with it
        // would hand the loop that replaced this one a banner about a request it never made.
        guard !Task.isCancelled else { return }
        retryNotice?.cancel()
        retryNotice = Task { [sleep] in
            try? await sleep(Self.retryingNotice)
            guard !Task.isCancelled else { return }
            self.showRetrying(message)
        }
    }

    private func showRetrying(_ message: String) {
        switch phase {
        // Still trying, so the banner is news. Anything else has moved on: live, asleep, archived,
        // refused, or closed by somebody leaving the workspace.
        case .connecting, .retrying: set(.retrying(message))
        default: return
        }
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
                noticeRetrying(wire.message)
                return .retry(after: nil)
            case .noAnswer(let detail), .unreadable(let detail):
                noticeRetrying(detail)
                return .retry(after: nil)
            case .cancelled:
                return .stop
            }
        }
        set(.retrying(error.localizedDescription))
        return .retry(after: nil)
    }

    private func outcome(for refusal: RunbloomRefusal) -> Outcome {
        if refusal.isMachineNotReady || refusal.isSharingInProgress {
            let wait = max(2, refusal.retryAfter ?? 5)
            // **Readiness does not go backwards inside a session.** A workspace this connection has
            // already had a stream from is not starting, whatever a refusal from runbloom.app says
            // while the two of them catch up: it is reconnecting, and saying "still starting" to
            // somebody who has been reading the conversation for ten minutes is a lie with a
            // spinner on it. `hasBeenAnswered` is cleared when the machine says it is going to
            // sleep, which is the one case where starting again is the truth.
            if hasBeenAnswered {
                noticeRetrying(refusal.message)
                return .retry(after: Double(wait))
            }
            set(.notReady(message: refusal.message, retryAfter: wait, detail: refusal.detail))
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
        // **No retry hint means asking again will not change the answer, so draw an end rather
        // than a wait.** The rule rather than a list of codes, on runbloom.app's own contract: it
        // sends `retry_after` where waiting is the answer. A machine whose build failed used to
        // fall through to `retrying` and be drawn as "Reconnecting…" for ever, which is the
        // spinner-with-no-end shape in its last hiding place.
        //
        // Two statuses are waits whatever the body says, and they are the ones that are not a
        // considered refusal at all: 429 means later by definition, and a 5xx is runbloom.app
        // having trouble rather than answering.
        if refusal.retryAfter == nil, refusal.status < 500, refusal.status != 429 {
            set(.unavailable(refusal.message))
            return .stop
        }
        set(.retrying(refusal.message))
        return .retry(after: refusal.retryAfter.map(Double.init))
    }

    private func advance(_ value: Int64) {
        if cursor.map({ value > $0 }) ?? true { cursor = value }
    }

    /// A phase written by the stream loop, or by a notice the loop scheduled.
    ///
    /// **Not from a cancelled task, because that task no longer speaks for the connection.**
    /// `suspend()` cancels the loop and says `closed`, but the loop is usually parked in an await
    /// (the token, the `workspace` read, the stream's response head) and carries on from there when
    /// it is answered. It used to say `live` on the next line, over the `closed` it had been
    /// cancelled for, and then leave: a phase of `live` with no stream behind it, which `resume`
    /// and `perform` both took at its word. The lifecycle methods write through `force`, because
    /// they are the ones deciding.
    private func set(_ new: Phase) {
        guard !Task.isCancelled else { return }
        force(new)
    }

    private func force(_ new: Phase) {
        guard new != phase else { return }
        phase = new
        continuation.yield(.phase(new))
    }
}
