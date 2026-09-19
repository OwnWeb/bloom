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
public struct OpeningHandoff: Sendable {
    let fetch: @Sendable () async throws -> RemoteOpening?
    let acknowledge: @Sendable () async throws -> Void
    let runtime: WorkspaceRuntime

    public init(fetch: @escaping @Sendable () async throws -> RemoteOpening?,
                acknowledge: @escaping @Sendable () async throws -> Void, runtime: WorkspaceRuntime) {
        self.fetch = fetch
        self.acknowledge = acknowledge
        self.runtime = runtime
    }

    public init(client: RunbloomClient, runtime: WorkspaceRuntime) {
        self.init(fetch: { try await client.opening() }, acknowledge: { try await client.acknowledgeOpening() }, runtime: runtime)
    }

    /// Whether a prompt was queued. Failures are said once on stderr and left for the next boot,
    /// because runbloom.app keeps an opening it was not told about until it expires.
    @discardableResult
    public func run() async -> Bool {
        do {
            // One kept by a boot that stopped before queueing it.
            if try await runtime.deliverStoredOpening() != nil { return true }
            guard let opening = try await fetch() else { return false }
            try await runtime.storeOpening(opening)
            try await acknowledge()
            return try await runtime.deliverStoredOpening() != nil
        } catch {
            FileHandle.standardError.write(Data("bloom-runner: the opening prompt was not queued yet: \(error)\n".utf8))
            return false
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
