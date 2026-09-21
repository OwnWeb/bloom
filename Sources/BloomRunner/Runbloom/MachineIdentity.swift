import BloomCore
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import NIOHTTP1

/// Owns the signing keys in the trusted Runner process. Persisted bytes go only through a
/// root-only installer into machine state. They never enter configuration, an environment value,
/// a command argument, a log line or a child agent process.
public actor MachineIdentitySigner {
    public static let capability = "machine_identity_proof_v1"
    public static let statePath = MachineIdentityStateStore.path

    private let machineID: CloudMachineID
    private let workspaceID: WorkspaceID
    private let targetPrefix: String
    private var current: Curve25519.Signing.PrivateKey
    private var pending: Curve25519.Signing.PrivateKey?
    private let persist: @Sendable (StoredMachineIdentity) throws -> Void
    private let now: @Sendable () -> Date
    private let requestID: @Sendable () -> UUID

    private init(
        machineID: CloudMachineID, workspaceID: WorkspaceID, targetPrefix: String,
        current: Curve25519.Signing.PrivateKey, pending: Curve25519.Signing.PrivateKey?,
        persist: @escaping @Sendable (StoredMachineIdentity) throws -> Void,
        now: @escaping @Sendable () -> Date, requestID: @escaping @Sendable () -> UUID
    ) {
        self.machineID = machineID
        self.workspaceID = workspaceID
        self.targetPrefix = targetPrefix
        self.current = current
        self.pending = pending
        self.persist = persist
        self.now = now
        self.requestID = requestID
    }

    public static func ephemeral(
        machineID: CloudMachineID = CloudMachineID("01jtestmachine0000000000000"),
        workspaceID: WorkspaceID,
        privateKey: Data? = nil, pendingPrivateKey: Data? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        requestID: @escaping @Sendable () -> UUID = UUID.init
    ) throws -> MachineIdentitySigner {
        let key = try privateKey.map(Curve25519.Signing.PrivateKey.init(rawRepresentation:))
            ?? Curve25519.Signing.PrivateKey()
        let pending = try pendingPrivateKey.map(Curve25519.Signing.PrivateKey.init(rawRepresentation:))
        return MachineIdentitySigner(
            machineID: machineID, workspaceID: workspaceID,
            targetPrefix: "/api/machine/workspaces/\(workspaceID)", current: key, pending: pending,
            persist: { _ in }, now: now, requestID: requestID
        )
    }

    public static func ephemeral(
        machineID: String = "01jtestmachine0000000000000", workspaceID: String,
        privateKey: Data? = nil, pendingPrivateKey: Data? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        requestID: @escaping @Sendable () -> UUID = UUID.init
    ) throws -> MachineIdentitySigner {
        try ephemeral(
            machineID: CloudMachineID(machineID), workspaceID: WorkspaceID(workspaceID),
            privateKey: privateKey, pendingPrivateKey: pendingPrivateKey,
            now: now, requestID: requestID
        )
    }

    static func generated(workspaceID: WorkspaceID) -> MachineIdentitySigner {
        MachineIdentitySigner(
            machineID: CloudMachineID("01jtestmachine0000000000000"), workspaceID: workspaceID,
            targetPrefix: "/api/machine/workspaces/\(workspaceID)",
            current: Curve25519.Signing.PrivateKey(), pending: nil,
            persist: { _ in }, now: Date.init, requestID: UUID.init
        )
    }

    public static func live(
        machineID: CloudMachineID, workspaceID: WorkspaceID, executable: String,
        path: String = statePath
    ) throws -> MachineIdentitySigner {
        let state: StoredMachineIdentity
        if let stored = try MachineIdentityStateStore.read(from: path) {
            state = stored
            guard state.version == 1 else { throw MachineIdentityError.unavailable("root-owned state has an unsupported version") }
            guard state.machineID == machineID else { throw MachineIdentityError.mismatchedMachine }
        } else {
            let created = Curve25519.Signing.PrivateKey()
            state = StoredMachineIdentity(
                machineID: machineID, privateKey: Base64URL.encode(created.rawRepresentation)
            )
            try MachineIdentityStateStore.install(state, executable: executable, path: path)
        }
        guard let currentBytes = Base64URL.decode(state.privateKey),
              let current = try? Curve25519.Signing.PrivateKey(rawRepresentation: currentBytes)
        else { throw MachineIdentityError.unavailable("root-owned state contains an invalid key") }
        let pending: Curve25519.Signing.PrivateKey?
        if let text = state.pendingPrivateKey {
            guard let bytes = Base64URL.decode(text),
                  let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
            else { throw MachineIdentityError.unavailable("root-owned state contains an invalid pending key") }
            pending = key
        } else {
            pending = nil
        }
        return MachineIdentitySigner(
            machineID: machineID, workspaceID: workspaceID,
            targetPrefix: "/api/machine/workspaces/\(workspaceID)", current: current, pending: pending,
            persist: { state in try MachineIdentityStateStore.install(state, executable: executable, path: path) },
            now: Date.init, requestID: UUID.init
        )
    }

    static func live(
        machineID: String, workspaceID: String, executable: String, path: String
    ) throws -> MachineIdentitySigner {
        try live(
            machineID: CloudMachineID(machineID), workspaceID: WorkspaceID(workspaceID),
            executable: executable, path: path
        )
    }

    public var descriptor: MachineIdentityDescriptor { Self.descriptor(for: current) }
    public var pendingDescriptor: MachineIdentityDescriptor? { pending.map(Self.descriptor(for:)) }

    func requestHeaders(
        method: HTTPMethod, path: String, body: Data?, usingPending: Bool = false
    ) throws -> MachineIdentityProofHeaders {
        let key: Curve25519.Signing.PrivateKey
        if usingPending {
            guard let pending else { throw MachineIdentityError.unavailable("there is no pending rotation key") }
            key = pending
        } else {
            key = current
        }
        let timestamp = Int64(now().timeIntervalSince1970)
        let identifier = requestID()
        let canonical = MachineIdentityCanonical.request(MachineIdentityRequestBinding(
            method: method, target: targetPrefix + path, machineID: machineID,
            workspaceID: workspaceID, timestamp: timestamp, requestID: identifier,
            body: body ?? Data()
        ))
        return MachineIdentityProofHeaders(
            keyID: Self.descriptor(for: key).keyID, timestamp: timestamp,
            requestID: identifier.uuidString.lowercased(),
            signature: Base64URL.encode(try key.signature(for: canonical))
        )
    }

    func registration() throws -> MachineIdentityRegistration {
        let timestamp = Int64(now().timeIntervalSince1970)
        let identifier = requestID()
        let publicKey = descriptor.publicKey
        let canonical = MachineIdentityCanonical.registration(MachineIdentityKeyBinding(
            operation: .register, method: .POST, target: targetPrefix + "/machine-identity",
            machineID: machineID, workspaceID: workspaceID, timestamp: timestamp,
            requestID: identifier, publicKey: publicKey, previousKeyID: nil
        ))
        return MachineIdentityRegistration(
            timestamp: timestamp, requestID: identifier.uuidString.lowercased(), publicKey: publicKey,
            signature: Base64URL.encode(try current.signature(for: canonical))
        )
    }

    func prepareRotation() throws -> (body: Data, headers: MachineIdentityProofHeaders) {
        if pending == nil {
            pending = Curve25519.Signing.PrivateKey()
            try persistState()
        }
        guard let pending else { throw MachineIdentityError.unavailable("a rotation key could not be prepared") }
        let timestamp = Int64(now().timeIntervalSince1970)
        let identifier = requestID()
        let next = Self.descriptor(for: pending)
        let previous = descriptor.keyID
        let canonical = MachineIdentityCanonical.registration(MachineIdentityKeyBinding(
            operation: .rotate, method: .PUT, target: targetPrefix + "/machine-identity",
            machineID: machineID, workspaceID: workspaceID, timestamp: timestamp,
            requestID: identifier, publicKey: next.publicKey, previousKeyID: previous
        ))
        let signature = Base64URL.encode(try pending.signature(for: canonical))
        let body = Data("{\"public_key\":\"\(next.publicKey)\",\"signature\":\"\(signature)\"}".utf8)
        let request = MachineIdentityCanonical.request(MachineIdentityRequestBinding(
            method: .PUT, target: targetPrefix + "/machine-identity", machineID: machineID,
            workspaceID: workspaceID, timestamp: timestamp, requestID: identifier, body: body
        ))
        let headers = MachineIdentityProofHeaders(
            keyID: previous, timestamp: timestamp, requestID: identifier.uuidString.lowercased(),
            signature: Base64URL.encode(try current.signature(for: request))
        )
        return (body, headers)
    }

    func commitRotation() throws {
        guard let pending else { return }
        current = pending
        self.pending = nil
        try persistState()
    }

    func discardRotation() throws {
        pending = nil
        try persistState()
    }

    private func persistState() throws {
        try persist(StoredMachineIdentity(
            machineID: machineID, privateKey: Base64URL.encode(current.rawRepresentation),
            pendingPrivateKey: pending.map { Base64URL.encode($0.rawRepresentation) }
        ))
    }

    private static func descriptor(for key: Curve25519.Signing.PrivateKey) -> MachineIdentityDescriptor {
        let publicBytes = key.publicKey.rawRepresentation
        return MachineIdentityDescriptor(
            publicKey: Base64URL.encode(publicBytes),
            keyID: MachineIdentityKeyID(
                SHA256.hash(data: publicBytes).map { String(format: "%02x", $0) }.joined()
            )
        )
    }

}
