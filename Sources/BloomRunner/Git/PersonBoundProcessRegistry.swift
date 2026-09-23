import Foundation
import Synchronization

/// A process identity read from the kernel. All four fields are compared on every credential use,
/// so a reused pid is a stranger even when an old registration was not cleaned up.
struct PersonBoundProcessIdentity: Codable, Sendable, Hashable {
    var pid: Int32
    var uid: UInt32
    var startTime: UInt64
    var cgroup: String
    var processGroup: Int32
}

/// Launches which may receive a v2 grant. There is deliberately no service or repository-script
/// case, so those processes cannot be registered by construction.
enum PersonBoundProcessPurpose: Sendable, Hashable {
    case turn(id: String, userID: String)
    case bootstrap
}

/// Registrations shared by the synchronous launch gate and the asynchronous credential broker.
///
/// `reserve` happens before the privileged helper starts. The helper's child changes uid and joins
/// its cgroup, then blocks at the gate until `register` has read those facts from `/proc`. Only the
/// successful reply lets it execute untrusted code.
final class PersonBoundProcessRegistry: @unchecked Sendable {
    struct Reservation: Sendable, Hashable {
        var id: UUID
        var nonce: String
        var uid: UInt32
        var cgroup: String
        var purpose: PersonBoundProcessPurpose
    }

    struct Binding: Sendable, Hashable {
        var reservation: Reservation
        var peerIdentity: PersonBoundProcessIdentity
        var leaderIdentity: PersonBoundProcessIdentity
    }

    private struct Pending {
        var reservation: Reservation
    }

    private struct Active {
        var reservation: Reservation
        var identity: PersonBoundProcessIdentity
    }

    private struct State {
        var nextUID: UInt32
        var pending: [String: Pending] = [:]
        var active: [UUID: Active] = [:]
        var registrations = 0
        var cleanupFailed = false
    }

    private let state: Mutex<State>
    private let identity: @Sendable (Int32) -> PersonBoundProcessIdentity?
    private let nonce: @Sendable () -> String
    private let identifier: @Sendable () -> UUID
    private let cgroupRoot: String
    private let teardown: @Sendable (PersonBoundProcessIdentity?, Reservation) -> Bool
    private let agentUID: UInt32?

    /// `agentUID` runs every reservation as that one user, which is how a machine runs them.
    ///
    /// **A fresh uid per reservation cost more than it protected.** Every launch got the next
    /// number from 200000, so a workspace's clone, its setup and each agent turn ran as different
    /// users, even for one person, and every file one of them wrote was a permission boundary for
    /// the next: git refused its own checkout, pushes refused it again, setup scripts could not
    /// write, and the agent could not read its own MCP config. The people sharing a workspace
    /// already share its checkout, its database and its services, so separating their Unix users
    /// separated almost nothing. What keeps a reservation's credential its own is the launch
    /// gate: the cgroup it binds, which one uid does not change.
    init(
        agentUID: UInt32? = nil,
        firstUID: UInt32 = 200_000,
        cgroupRoot: String = "/sys/fs/cgroup/bloom-person-bound",
        identity: @escaping @Sendable (Int32) -> PersonBoundProcessIdentity? = { PersonBoundProcIdentity.read($0) },
        nonce: @escaping @Sendable () -> String = { UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "") },
        identifier: @escaping @Sendable () -> UUID = UUID.init,
        teardown: @escaping @Sendable (PersonBoundProcessIdentity?, Reservation) -> Bool = { _, _ in true }
    ) {
        state = Mutex(State(nextUID: firstUID))
        self.cgroupRoot = cgroupRoot
        self.identity = identity
        self.nonce = nonce
        self.identifier = identifier
        self.teardown = teardown
        self.agentUID = agentUID
    }

    func reserve(_ purpose: PersonBoundProcessPurpose) -> Reservation? {
        state.withLock { state in
            guard !state.cleanupFailed else { return nil }
            let id = identifier()
            let token = nonce()
            let uid = agentUID ?? state.nextUID
            if agentUID == nil {
                state.nextUID = state.nextUID == 299_999 ? 200_000 : state.nextUID + 1
            }
            let reservation = Reservation(
                id: id, nonce: token, uid: uid,
                cgroup: cgroupRoot + "/" + id.uuidString.lowercased(), purpose: purpose
            )
            state.pending[token] = Pending(reservation: reservation)
            return reservation
        }
    }

    /// Called by the launch gate from the helper's child. Registration is complete before true is
    /// returned and before the gate sends its one-byte permission to execute.
    func register(nonce: String, peer: LocalSocket.Peer) -> Reservation? {
        guard let observed = identity(peer.pid), observed.uid == peer.uid else { return nil }
        return state.withLock { state in
            guard !state.cleanupFailed,
                  let pending = state.pending[nonce],
                  pending.reservation.uid == peer.uid,
                  observed.cgroup == pending.reservation.cgroup,
                  observed.processGroup == observed.pid else { return nil }
            state.pending.removeValue(forKey: nonce)
            state.active[pending.reservation.id] = Active(reservation: pending.reservation, identity: observed)
            state.registrations += 1
            return pending.reservation
        }
    }

    /// Refuses an unknown peer, a stale start time, a changed uid and a process moved out of the
    /// registered cgroup. The request body contributes nothing to this decision.
    func reservation(for peer: LocalSocket.Peer) -> Reservation? {
        binding(for: peer)?.reservation
    }

    /// Returns the kernel identity which was validated for this exact peer. The broker passes this
    /// identity to the privileged command attestor and validates it again before claiming a grant.
    ///
    /// **A launch is its cgroup, not its process group.** This also required the caller to share
    /// the sandbox leader's process group, and Claude Code starts every Bash command detached, in a
    /// process group of its own, so every `git push` an agent ran was refused as "matches no live
    /// launch-gate reservation" (Runner test.57, uid 1002). The process group never said anything
    /// the cgroup does not say better: the root launcher makes one cgroup per launch, every
    /// descendant inherits it whatever process group or session it starts, and `cgroup.procs` is
    /// root's, so nothing unprivileged moves itself in or out. A process group is the caller's to
    /// change with one `setpgid`. The uid, the start times and the leader being alive and unchanged
    /// are all still checked.
    func binding(for peer: LocalSocket.Peer) -> Binding? {
        guard let observed = identity(peer.pid), observed.uid == peer.uid else { return nil }
        return state.withLock { state in
            guard !state.cleanupFailed,
                  let active = state.active.values.first(where: { active in
                guard active.reservation.uid == observed.uid,
                      active.reservation.cgroup == observed.cgroup,
                      identity(active.identity.pid) == active.identity else { return false }
                return true
            }) else { return nil }
            return Binding(
                reservation: active.reservation, peerIdentity: observed,
                leaderIdentity: active.identity
            )
        }
    }

    /// Removes authority while the process still exists, then kills and removes what belonged to
    /// it. The order is the security property and is kept inside this one synchronous operation.
    func forgetBeforeTeardown(_ id: UUID) {
        let removed: (PersonBoundProcessIdentity?, Reservation)? = state.withLock { state in
            if let active = state.active.removeValue(forKey: id) {
                return (active.identity, active.reservation)
            }
            guard let entry = state.pending.first(where: { $0.value.reservation.id == id }) else { return nil }
            state.pending.removeValue(forKey: entry.key)
            return (nil, entry.value.reservation)
        }
        if let removed, !teardown(removed.0, removed.1) {
            state.withLock { $0.cleanupFailed = true }
        }
    }

    var counts: (pending: Int, active: Int) {
        state.withLock { ($0.pending.count, $0.active.count) }
    }

    var registrationCount: Int { state.withLock(\.registrations) }

    var isHealthy: Bool { state.withLock { !$0.cleanupFailed } }
}

enum PersonBoundProcIdentity {
    static func read(_ pid: Int32, root: String = "/proc") -> PersonBoundProcessIdentity? {
        guard pid > 1,
              let stat = try? String(contentsOfFile: root + "/\(pid)/stat", encoding: .utf8),
              let close = stat.lastIndex(of: ")"),
              let status = try? String(contentsOfFile: root + "/\(pid)/status", encoding: .utf8),
              let cgroups = try? String(contentsOfFile: root + "/\(pid)/cgroup", encoding: .utf8) else { return nil }
        // Fields after the final `)` start at field 3. The process start time is field 22.
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        guard fields.count > 19, let processGroup = Int32(fields[2]), let start = UInt64(fields[19]) else { return nil }
        guard let uidLine = status.split(separator: "\n").first(where: { $0.hasPrefix("Uid:") }),
              let uid = uidLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).dropFirst().first.flatMap({ UInt32($0) }) else { return nil }
        guard let unified = cgroups.split(separator: "\n").first(where: { $0.hasPrefix("0::") }) else { return nil }
        let cgroup = String(unified.dropFirst(3))
        guard !cgroup.isEmpty else { return nil }
        return PersonBoundProcessIdentity(
            pid: pid, uid: uid, startTime: start, cgroup: "/sys/fs/cgroup" + cgroup, processGroup: processGroup
        )
    }
}
