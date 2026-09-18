import Foundation
import Synchronization

/// The one workspace's front door: mutations take a permit, and an archive closes the door and
/// waits for everything already inside to finish before it touches the worktree.
///
/// #163's `ServerWorkspaceAdmissions`, with the per-workspace table gone because a machine holds
/// one workspace. The rule it exists for is unchanged: an RPC and an agent's bridge call take the
/// same permits, so an archive cannot miss a tool call that was paused inside agent discovery when
/// the archive began.
final class RemoteAdmissions: Sendable {
    struct Permit: Sendable {
        fileprivate let owner: RemoteAdmissions
        fileprivate let id: UUID
        func release() { owner.release(id) }
    }

    private enum Phase { case open, closing, closed }

    private struct State {
        var phase = Phase.open
        var stopped = false
        var permits: Set<UUID> = []
        var drainWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var isOpen: Bool { state.withLock { $0.phase == .open && !$0.stopped } }
    var hasActiveOperations: Bool { state.withLock { !$0.permits.isEmpty } }

    func admit() throws -> Permit {
        try state.withLock { state in
            guard !state.stopped else { throw RemoteFailure.shuttingDown }
            switch state.phase {
            case .open: break
            case .closing: throw RemoteFailure(.workspaceChanging, "This Bloom Cloud workspace is being archived.")
            case .closed: throw RemoteFailure(.workspaceChanging, "This Bloom Cloud workspace has been archived.")
            }
            let id = UUID()
            state.permits.insert(id)
            return Permit(owner: self, id: id)
        }
    }

    /// Closes the door, or refuses when somebody else already is closing it.
    func beginClosing() throws {
        try state.withLock { state in
            guard !state.stopped else { throw RemoteFailure.shuttingDown }
            guard state.phase == .open else { throw RemoteFailure(.workspaceChanging, "This Bloom Cloud workspace is already being archived.") }
            state.phase = .closing
        }
    }

    /// Waits until every permit taken before the door closed has been released.
    func drain() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> Bool in
                if state.permits.isEmpty { return true }
                state.drainWaiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    /// Ends a closing: for good after an archive, or open again when the archive went back to a
    /// fresh preview because something moved.
    func finishClosing(closed: Bool) {
        state.withLock { state in
            guard state.phase == .closing else { return }
            state.phase = closed ? .closed : .open
        }
    }

    func stop() {
        state.withLock { $0.stopped = true }
    }

    private func release(_ id: UUID) {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            guard state.permits.remove(id) != nil, state.permits.isEmpty else { return [] }
            defer { state.drainWaiters.removeAll() }
            return state.drainWaiters
        }
        for waiter in waiters { waiter.resume() }
    }
}
