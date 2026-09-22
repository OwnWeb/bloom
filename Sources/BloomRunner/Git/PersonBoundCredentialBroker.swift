import Foundation
import Synchronization

/// The in-memory v2 grant broker. A rotating grant is claimed under one lock before the network
/// exchange begins, so it cannot be presented twice. `forget` is deliberately synchronous: the
/// process cleanup path can revoke both the grant and its kernel registration before teardown.
/// A failed or cancelled exchange never retries or falls back to legacy credentials.
final class PersonBoundCredentialBroker: @unchecked Sendable {
    typealias Fetch = @Sendable (
        _ grant: String, _ operation: PersonBoundGithubOperation, _ requestID: UUID
    ) async throws -> PersonBoundGithubCredentials

    private let repository: String
    private let registry: PersonBoundProcessRegistry
    private let operation: @Sendable (
        LocalSocket.Peer, PersonBoundProcessRegistry.Binding, PersonBoundGithubOperation
    ) -> PersonBoundOperationAttestation?
    private let fetch: Fetch
    private let requestID: @Sendable () -> UUID
    private struct Lease {
        var grant: PersonBoundGithubGrant?
        var requestID: UUID?
        var operationIdentity: PersonBoundOperationIdentity?
        var usedOperationIdentities: Set<PersonBoundOperationIdentity> = []
        var revoked = false
    }

    private let leases = Mutex<[UUID: Lease]>([:])

    init(repository: String, registry: PersonBoundProcessRegistry,
         operation: @escaping @Sendable (
             LocalSocket.Peer, PersonBoundProcessRegistry.Binding, PersonBoundGithubOperation
         ) -> PersonBoundOperationAttestation?,
         requestID: @escaping @Sendable () -> UUID = UUID.init, fetch: @escaping Fetch) {
        self.repository = repository.lowercased()
        self.registry = registry
        self.operation = operation
        self.requestID = requestID
        self.fetch = fetch
    }

    func install(_ grant: PersonBoundGithubGrant, for reservation: PersonBoundProcessRegistry.Reservation) {
        leases.withLock { $0[reservation.id] = Lease(grant: grant) }
    }

    func forget(_ reservation: PersonBoundProcessRegistry.Reservation) {
        leases.withLock { leases in
            guard var lease = leases[reservation.id] else { return }
            guard lease.requestID != nil else {
                leases.removeValue(forKey: reservation.id)
                return
            }
            lease.grant = nil
            lease.revoked = true
            leases[reservation.id] = lease
        }
    }

    func credential(
        for request: PersonBoundCredentialRequest, peer: LocalSocket.Peer?
    ) async -> PersonBoundCredentialAnswer? {
        /*
         * **Every refusal below used to be a bare nil.** git reports all of them as one sentence,
         * "unable to get password from user", the Runner printed nothing beside it, and a whole
         * day went into the wrong half of the system as a result. The reasons cost nothing: this
         * path runs once per network git command, and a refusal is already the unusual case.
         */
        func refuse(_ reason: String) -> PersonBoundCredentialAnswer? {
            FileHandle.standardError.write(Data(
                "bloom-runner: the credential exchange was refused: \(reason)\n".utf8
            ))

            return nil
        }
        guard request.version == 2 else { return refuse("a version \(request.version) request") }
        guard request.repository.lowercased() == repository else {
            return refuse("it asked for \(request.repository), and this machine holds \(repository)")
        }
        guard let peer else { return refuse("the socket reported no peer credentials") }
        guard let binding = registry.binding(for: peer) else {
            return refuse("pid \(peer.pid) uid \(peer.uid) matches no live launch-gate reservation")
        }
        guard let attestation = operation(peer, binding, request.operation) else {
            return refuse("the root attestor would not vouch for pid \(peer.pid)")
        }
        guard registry.binding(for: peer) == binding else {
            return refuse("the reservation changed while pid \(peer.pid) was being checked")
        }
        let reservation = binding.reservation
        let exchangeID = requestID()
        guard let grant = leases.withLock({ leases -> PersonBoundGithubGrant? in
            guard var lease = leases[reservation.id], !lease.revoked,
                  lease.requestID == nil,
                  !lease.usedOperationIdentities.contains(attestation.identity),
                  let grant = lease.grant, grant.expiresAt > Date() else { return nil }
            lease.grant = nil
            lease.requestID = exchangeID
            lease.operationIdentity = attestation.identity
            lease.usedOperationIdentities.insert(attestation.identity)
            leases[reservation.id] = lease
            return grant
        }) else {
            return refuse("no grant is available for this reservation, or one is already in flight")
        }
        do {
            let issued = try await fetch(grant.token, attestation.operation, exchangeID)
            guard issued.username == "x-access-token", !issued.token.isEmpty,
                  issued.expiresAt > Date(), issued.nextGrant.expiresAt > Date() else {
                closeExchange(reservation.id, exchangeID: exchangeID)
                return nil
            }
            guard registry.binding(for: peer) == binding,
                  operation(peer, binding, request.operation) == attestation else {
                closeExchange(reservation.id, exchangeID: exchangeID)
                return nil
            }
            let installed = leases.withLock { leases -> Bool in
                guard var lease = leases[reservation.id], lease.requestID == exchangeID,
                      lease.operationIdentity == attestation.identity, !lease.revoked else {
                    leases.removeValue(forKey: reservation.id)
                    return false
                }
                lease.grant = issued.nextGrant
                lease.requestID = nil
                lease.operationIdentity = nil
                leases[reservation.id] = lease
                return true
            }
            guard installed else { return nil }
            return PersonBoundCredentialAnswer(username: issued.username, token: issued.token, expiresAt: issued.expiresAt)
        } catch {
            // **Say what went wrong before closing the lease.** This is the one refusal that costs
            // a person their clone with no sentence anywhere: runbloom.app said no, or could not
            // be reached, and the machine answered its own caller by closing the socket.
            FileHandle.standardError.write(Data(
                "bloom-runner: the credential exchange with runbloom.app failed: \(error)\n".utf8
            ))
            // The server may have rotated a grant before a connection was lost. Reusing it would
            // turn an uncertain operation into a replay, so this lease is closed permanently.
            leases.withLock { leases in
                if leases[reservation.id]?.requestID == exchangeID {
                    leases.removeValue(forKey: reservation.id)
                }
            }
            return nil
        }
    }

    private func closeExchange(_ reservationID: UUID, exchangeID: UUID) {
        leases.withLock { leases in
            if leases[reservationID]?.requestID == exchangeID {
                leases.removeValue(forKey: reservationID)
            }
        }
    }
}

struct PersonBoundCredentialRequest: Codable, Sendable, Hashable {
    var version: Int = 2
    var repository: String
    /// What the caller is about to do, stated by the caller.
    ///
    /// **The supervisor used to work this out by reading the caller's process tree**, and that is
    /// why no Cloud workspace started for a day: it meant reading `/proc/<pid>/exe` of processes
    /// that are not dumpable, which needs CAP_SYS_PTRACE and no machine grants it, and it meant
    /// hardcoding how git spawns its helpers, which is not a thing git promises and which it does
    /// differently from one version to the next. Four separate refusals came out of that shape
    /// being wrong, each hidden behind the last.
    ///
    /// Taking the caller's word is worth what the sandbox is worth, which is the same thing every
    /// other decision here already rests on: the launch gate's one-time nonce, the uid the kernel
    /// reports through SO_PEERCRED, the cgroup and the process group. A process that could lie
    /// about this is a process already running as that person, inside that person's sandbox, with
    /// that person's access. What it cannot do is widen what the credential is good for: runbloom
    /// issues a token scoped to what that person may do, and that is decided on the server.
    var operation: PersonBoundGithubOperation = .gitRead
}

struct PersonBoundCredentialAnswer: Codable, Sendable, Hashable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    var username: String
    var token: String
    var expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case username, token
        case expiresAt = "expires_at"
    }

    var description: String { "PersonBoundCredentialAnswer(username: \(username), expiresAt: \(expiresAt), token: [REDACTED])" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["description": description]) }
}
