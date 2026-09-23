import BloomCore
import Foundation

/// The new machine's half of an opening prompt: fetch it, keep it, say so, queue it.
///
/// **In that order, because each step is safe to repeat and the order is what makes it so.** The
/// opening is kept on this machine before runbloom.app is told it has arrived, so a machine that
/// stops between the two fetches the same opening again on its next boot rather than losing it; and
/// it is only queued from the kept copy, which `deliverStoredOpening` never queues twice for one
/// turn. runbloom.app deletes its copy when told, so the words do not outlive the hand-off by more
/// than one call. See `RemoteOpening`.
///
/// Run after setup on every boot. A workspace a person made has no opening, which costs one `GET`
/// answered 404; a machine that replaces one whose setup failed fetches the same opening and turn.
///
/// **The fetch is asked again until runbloom.app answers it.** It used to be asked once a boot,
/// and on test.55 that one `GET` ran into `HTTPClientError.deadlineExceeded` at 15 seconds: the
/// opening turn sat `queued` on runbloom.app for as long as the machine stayed up, because nothing
/// asked again before the next boot. Asking again is safe on runbloom.app's side:
/// `FetchCloudWorkspaceOpeningAction` marks the opening fetched on the first read and answers the
/// same opening to every read after it until it is acknowledged or expires, so an answer lost on
/// the way here does not lose the prompt.
public struct OpeningHandoff: Sendable {
    let fetch: @Sendable () async throws -> RemoteOpening?
    let acknowledge: @Sendable () async throws -> Void
    let runtime: WorkspaceRuntime
    let retryDelay: Duration
    let longestRetryDelay: Duration

    /// `retryDelay` doubles between attempts up to `longestRetryDelay`. Parameters so a test can
    /// make them short.
    public init(fetch: @escaping @Sendable () async throws -> RemoteOpening?,
                acknowledge: @escaping @Sendable () async throws -> Void, runtime: WorkspaceRuntime,
                retryDelay: Duration = .seconds(2), longestRetryDelay: Duration = .seconds(60)) {
        self.fetch = fetch
        self.acknowledge = acknowledge
        self.runtime = runtime
        self.retryDelay = retryDelay
        self.longestRetryDelay = max(retryDelay, longestRetryDelay)
    }

    public init(client: RunbloomClient, runtime: WorkspaceRuntime) {
        self.init(fetch: { try await client.opening() }, acknowledge: { try await client.acknowledgeOpening() }, runtime: runtime)
    }

    /// Whether a prompt was queued. A fetch that failed for the network or for runbloom.app itself
    /// is asked again, with a growing pause, until runbloom.app answers: the opening, or 404 for
    /// none. Anything else is said once on stderr and left for the next boot, because runbloom.app
    /// keeps an opening it was not told about until it expires. A cancelled task, which is the
    /// machine stopping, ends the wait quietly.
    ///
    /// **Acknowledging is not a condition of queueing.** It used to be, so an acknowledgement that
    /// failed held the person's instruction back until the next boot. Once the opening is kept here
    /// it is queued whether or not runbloom.app heard, and an unacknowledged one that comes back is
    /// recognised by its turn and acknowledged again rather than queued twice.
    @discardableResult
    public func run() async -> Bool {
        do {
            // One kept by a boot that stopped before queueing it.
            var queued = try await runtime.deliverStoredOpening() != nil
            guard let opening = try await fetchUntilAnswered() else { return queued }
            if try await runtime.hasDeliveredOpening(turnID: opening.turnID) {
                await acknowledgeOrSay()
                return queued
            }
            try await runtime.storeOpening(opening)
            await acknowledgeOrSay()
            queued = try await runtime.deliverStoredOpening() != nil || queued
            return queued
        } catch is CancellationError {
            return false
        } catch {
            FileHandle.standardError.write(Data("bloom-runner: the opening prompt was not queued yet: \(error)\n".utf8))
            return false
        }
    }

    /// The opening, or nil when runbloom.app says there is none, asked for again for as long as the
    /// failure is one a later attempt could get past. Throws what runbloom.app refused, and
    /// `CancellationError` when the machine stops while this waits.
    private func fetchUntilAnswered() async throws -> RemoteOpening? {
        var delay = retryDelay
        while true {
            do {
                return try await fetch()
            } catch let error as RunbloomError where Self.isTransient(error) {
                FileHandle.standardError.write(Data(
                    "bloom-runner: the opening prompt could not be fetched yet, asking again in \(delay): \(error)\n".utf8
                ))
                try await Task.sleep(for: delay)
                delay = min(delay * 2, longestRetryDelay)
            }
        }
    }

    /// The network, a timeout or a 5xx (all `unreachable`), or runbloom.app asking to be called
    /// later. Narrower than `isWorthRetrying`, which also counts an answer this machine could not
    /// decode: that one decodes no better the next time, and asking for ever is not an answer.
    static func isTransient(_ error: RunbloomError) -> Bool {
        if case .unreachable = error { return true }
        return error.isBackpressure
    }

    /// Said once on stderr when it fails, and tried again the next time the opening is fetched.
    private func acknowledgeOrSay() async {
        do {
            try await acknowledge()
        } catch {
            FileHandle.standardError.write(Data("bloom-runner: runbloom.app was not told the opening arrived: \(error)\n".utf8))
        }
    }
}

extension RunbloomClient {
    /// The opening prompt runbloom.app holds for this workspace, or nil when there is none.
    public func opening() async throws -> RemoteOpening? {
        struct Answer: Decodable { var opening: RemoteOpening }
        do {
            let data = try await send(.GET, "/opening", expecting: [200])
            return try decode(Answer.self, data, status: 200).opening
        } catch RunbloomError.refused(404, _, _, _, _), RunbloomError.unexpected(404) {
            // With runbloom.app's `not_found` body or without one: either way there is nothing.
            return nil
        }
    }

    /// Tells runbloom.app this machine has kept the opening, so it can forget it. Always 204.
    public func acknowledgeOpening() async throws {
        _ = try await send(.DELETE, "/opening", expecting: [200, 204])
    }
}
