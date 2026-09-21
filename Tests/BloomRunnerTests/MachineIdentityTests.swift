import AsyncHTTPClient
import BloomCore
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import NIOHTTP1
import Testing
@testable import BloomRunner

@Suite(.serialized)
struct MachineIdentityTests {
    private let seed = Data(0..<32)
    private let workspaceID = "01jworkspace"
    private let machineID = "01jmachine"
    private let requestUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let issuedAt = Date(timeIntervalSince1970: 1_720_000_000)

    @Test("registration bytes and Ed25519 signature match the server v1 vector")
    func registrationVector() async throws {
        let signer = try MachineIdentitySigner.ephemeral(
            machineID: machineID, workspaceID: workspaceID, privateKey: seed,
            now: { issuedAt }, requestID: { requestUUID }
        )
        let registration = try await signer.registration()
        let descriptor = await signer.descriptor

        #expect(descriptor.publicKey == "A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg")
        #expect(descriptor.keyID.rawValue == "56475aa75463474c0285df5dbf2bcab73da651358839e9b77481b2eab107708c")
        let canonical = MachineIdentityCanonical.registration(MachineIdentityKeyBinding(
            operation: .register, method: .POST,
            target: "/api/machine/workspaces/01jworkspace/machine-identity",
            machineID: CloudMachineID(machineID), workspaceID: WorkspaceID(workspaceID),
            timestamp: 1_720_000_000, requestID: requestUUID,
            publicKey: descriptor.publicKey, previousKeyID: nil
        ))
        #expect(String(decoding: canonical, as: UTF8.self) == #"{"version":"1","operation":"register","method":"POST","target":"/api/machine/workspaces/01jworkspace/machine-identity","machine_id":"01jmachine","workspace_id":"01jworkspace","issued_at":1720000000,"request_id":"11111111-2222-3333-4444-555555555555","public_key":"A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg","previous_key_id":null}"#)
        let publicKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey
        let generatedSignature = try #require(Base64URL.decode(registration.signature))
        let serverVector = try #require(Base64URL.decode("-rme1dQUXKKnETrOua2YWkesU4n6aftP_3MtaeBM7CS896cOaetY1Zl8dyfbEwnit-vUCAdGTDH5ZVCEFOOaAQ"))
        #expect(publicKey.isValidSignature(generatedSignature, for: canonical))
        #expect(publicKey.isValidSignature(serverVector, for: canonical))
    }

    @Test("request canonicalization binds method, exact target, identities, request, and raw body")
    func requestVectorAndAdversarialBindings() async throws {
        let signer = try MachineIdentitySigner.ephemeral(
            machineID: machineID, workspaceID: workspaceID, privateKey: seed,
            now: { issuedAt }, requestID: { requestUUID }
        )
        let body = Data(#"{"revision":42}"#.utf8)
        let path = "/summary?after=a%20b"
        let headers = try await signer.requestHeaders(method: .POST, path: path, body: body)
        #expect(headers.requestID == requestUUID.uuidString.lowercased())

        let expected = #"{"version":"1","operation":"request","method":"POST","target":"/api/machine/workspaces/01jworkspace/summary?after=a%20b","machine_id":"01jmachine","workspace_id":"01jworkspace","issued_at":1720000000,"request_id":"11111111-2222-3333-4444-555555555555","content_sha256":"8e127386b0998b155f741c3d523b20f2205aa75288e5e4694af0266ef71a6977"}"#
        let canonical = MachineIdentityCanonical.request(MachineIdentityRequestBinding(
            method: .POST, target: "/api/machine/workspaces/01jworkspace" + path,
            machineID: CloudMachineID(machineID), workspaceID: WorkspaceID(workspaceID),
            timestamp: 1_720_000_000, requestID: requestUUID, body: body
        ))
        #expect(String(decoding: canonical, as: UTF8.self) == expected)

        let publicKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey
        let signature = try #require(Base64URL.decode(headers.signature))
        #expect(publicKey.isValidSignature(signature, for: canonical))
        let serverVector = try #require(Base64URL.decode("vBXHvNwH08F_QIsTXiPXTdrr3hNNWalaVIWd3_BTIVy-firl8YFLklMkza7Vl8q9Lqp7Qn5OabFI4ijYmzOoDA"))
        #expect(publicKey.isValidSignature(serverVector, for: canonical))
        let wrongKey = Curve25519.Signing.PrivateKey().publicKey
        #expect(!wrongKey.isValidSignature(signature, for: canonical))
        let mutations: [Data] = [
            requestBinding(method: .PUT, target: "/api/machine/workspaces/01jworkspace" + path, body: body),
            requestBinding(method: .POST, target: "/api/machine/workspaces/01jworkspace/summary?after=a+b", body: body),
            requestBinding(method: .POST, target: "/api/machine/workspaces/01jworkspace" + path, machineID: "wrong", body: body),
            requestBinding(method: .POST, target: "/api/machine/workspaces/01jworkspace" + path, workspaceID: "wrong", body: body),
            requestBinding(method: .POST, target: "/api/machine/workspaces/01jworkspace" + path, timestamp: 1_720_000_001, body: body),
            requestBinding(method: .POST, target: "/api/machine/workspaces/01jworkspace" + path, requestID: UUID(), body: body),
            requestBinding(method: .POST, target: "/api/machine/workspaces/01jworkspace" + path, body: body + Data([0])),
        ]
        #expect(mutations.allSatisfy { !publicKey.isValidSignature(signature, for: $0) })
    }

    @Test("root-controlled state survives reboot, keeps restrictive modes, and recovers rotation")
    func persistentStateAndRotation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bloom-identity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("identity/state.json").path
        let first = try MachineIdentitySigner.live(
            machineID: machineID, workspaceID: workspaceID, executable: "/unused", path: path
        )
        let descriptor = await first.descriptor
        _ = try await first.prepareRotation()
        let pending = try #require(await first.pendingDescriptor)

        let rebooted = try MachineIdentitySigner.live(
            machineID: machineID, workspaceID: workspaceID, executable: "/unused", path: path
        )
        #expect(await rebooted.descriptor == descriptor)
        #expect(await rebooted.pendingDescriptor == pending)
        try await rebooted.commitRotation()
        let committed = try MachineIdentitySigner.live(
            machineID: machineID, workspaceID: workspaceID, executable: "/unused", path: path
        )
        #expect(await committed.descriptor == pending)
        #expect(await committed.pendingDescriptor == nil)

        let fileMode = try #require((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]) as? NSNumber)
        let directoryMode = try #require((try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("identity").path)[.posixPermissions]) as? NSNumber)
        #expect(fileMode.intValue & 0o777 == 0o640)
        #expect(directoryMode.intValue & 0o777 == 0o750)
    }

    @Test("rotation binds the old request proof and new-key proof to one request id")
    func rotationProtocol() async throws {
        let fake = try await FakeControlServer.start(workspaceID: workspaceID)
        let signer = try MachineIdentitySigner.ephemeral(
            machineID: machineID, workspaceID: workspaceID, privateKey: seed,
            pendingPrivateKey: Data(32..<64),
            now: { issuedAt }, requestID: { requestUUID }
        )
        let old = await signer.descriptor
        let pending = try #require(await signer.pendingDescriptor)
        fake.script("PUT", "/machine-identity", .json(200, [
            "version": 1, "key_id": pending.keyID.rawValue,
            "rotated_at": "2026-09-21T00:00:00Z",
        ]))

        let client = RunbloomClient(
            baseURL: fake.baseURL, workspaceID: workspaceID, secret: fake.secret,
            http: .shared, identity: signer
        )
        let rotated = try await client.rotateMachineIdentity()
        #expect(rotated == pending)
        #expect(await signer.descriptor == pending)
        #expect(await signer.pendingDescriptor == nil)
        let request = try #require(fake.requests("PUT", "/machine-identity").first)
        #expect(request.proof["key-id"] == old.keyID.rawValue)
        #expect(request.proof["timestamp"] == "1720000000")
        #expect(request.proof["request-id"] == requestUUID.uuidString.lowercased())
        let rotation = try #require(request.json as? [String: String])
        #expect(rotation["previous_key_id"] == nil)
        let oldPublic = try Curve25519.Signing.PublicKey(
            rawRepresentation: #require(Base64URL.decode(old.publicKey))
        )
        let oldSignature = try #require(request.proof["signature"].flatMap(Base64URL.decode))
        let requestCanonical = MachineIdentityCanonical.request(MachineIdentityRequestBinding(
            method: .PUT, target: "/api/machine/workspaces/01jworkspace/machine-identity",
            machineID: CloudMachineID(machineID), workspaceID: WorkspaceID(workspaceID),
            timestamp: 1_720_000_000, requestID: requestUUID, body: request.body
        ))
        #expect(oldPublic.isValidSignature(oldSignature, for: requestCanonical))
        let newPublicText = try #require(rotation["public_key"])
        let newPublic = try Curve25519.Signing.PublicKey(
            rawRepresentation: #require(Base64URL.decode(newPublicText))
        )
        let newSignature = try #require(rotation["signature"].flatMap(Base64URL.decode))
        let rotateCanonical = MachineIdentityCanonical.registration(MachineIdentityKeyBinding(
            operation: .rotate, method: .PUT,
            target: "/api/machine/workspaces/01jworkspace/machine-identity",
            machineID: CloudMachineID(machineID), workspaceID: WorkspaceID(workspaceID),
            timestamp: 1_720_000_000, requestID: requestUUID, publicKey: newPublicText,
            previousKeyID: old.keyID
        ))
        #expect(newPublic.isValidSignature(newSignature, for: rotateCanonical))

        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rotated-workspace-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: configURL) }
        var configuration = try Self.configuration(token: nil)
        configuration.machineIdentity?.keyID = old.keyID
        try JSONEncoder().encode(configuration).write(to: configURL)
        try await MachineIdentityBootstrap.establish(
            configuration: &configuration, client: client, signer: signer,
            configurationPath: configURL.path
        )
        #expect(configuration.machineIdentity?.keyID == pending.keyID)
        await fake.stop()
    }

    @Test("registration succeeds once, erases bootstrap authority, and then proves liveness")
    func registrationLifecycle() async throws {
        let fake = try await FakeControlServer.start(workspaceID: workspaceID)
        fake.script("GET", "/members", .refusal(status: 401, code: "invalid_machine_proof", message: "Invalid proof."))
        fake.script("POST", "/machine-identity", .json(201, [
            "version": 1,
            "key_id": "56475aa75463474c0285df5dbf2bcab73da651358839e9b77481b2eab107708c",
            "registered_at": "2026-09-21T00:00:00Z",
        ]))
        let signer = try MachineIdentitySigner.ephemeral(
            machineID: machineID, workspaceID: workspaceID, privateKey: seed,
            now: { issuedAt }, requestID: UUID.init
        )
        let client = RunbloomClient(
            baseURL: fake.baseURL, workspaceID: workspaceID, secret: fake.secret,
            http: .shared, identity: signer
        )
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: configURL) }
        var configuration = try Self.configuration(token: String(repeating: "r", count: 64))
        try JSONEncoder().encode(configuration).write(to: configURL)

        try await MachineIdentityBootstrap.establish(
            configuration: &configuration, client: client, signer: signer,
            configurationPath: configURL.path, now: Date(timeIntervalSince1970: 1_719_999_000)
        )
        #expect(configuration.machineIdentity?.registrationToken == nil)
        #expect(configuration.machineIdentity?.keyID == (await signer.descriptor).keyID)
        let registration = try #require(fake.requests("POST", "/machine-identity").first)
        #expect(registration.proof["registration"] == String(repeating: "r", count: 64))
        #expect(registration.proof["version"] == "1")
        #expect(registration.proof["key-id"] == nil)
        let persisted = try JSONDecoder().decode(MachineConfiguration.self, from: Data(contentsOf: configURL))
        #expect(persisted.machineIdentity?.registrationToken == nil)
        let persistedText = String(decoding: try Data(contentsOf: configURL), as: UTF8.self)
        #expect(!persistedText.contains(String(repeating: "r", count: 64)))
        let privateKeyText = Base64URL.encode(seed)
        #expect(!persistedText.contains(privateKeyText))
        #expect(!String(decoding: registration.body, as: UTF8.self).contains(privateKeyText))
        await fake.stop()
    }

    @Test("an accepted registration with a lost response is recovered without replaying bootstrap")
    func interruptedRegistrationIsIdempotent() async throws {
        let fake = try await FakeControlServer.start(workspaceID: workspaceID)
        fake.script("GET", "/members", .refusal(
            status: 401, code: "invalid_machine_proof", message: "Registration is not visible yet."
        ))
        fake.script("POST", "/machine-identity", .refusal(
            status: 401, code: "invalid_machine_proof", message: "Registration was already consumed."
        ))
        let signer = try MachineIdentitySigner.ephemeral(
            machineID: machineID, workspaceID: workspaceID, privateKey: seed
        )
        let client = RunbloomClient(
            baseURL: fake.baseURL, workspaceID: workspaceID, secret: fake.secret,
            http: .shared, identity: signer
        )
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: configURL) }
        var configuration = try Self.configuration(token: String(repeating: "s", count: 64))
        try JSONEncoder().encode(configuration).write(to: configURL)

        try await MachineIdentityBootstrap.establish(
            configuration: &configuration, client: client, signer: signer,
            configurationPath: configURL.path, now: Date(timeIntervalSince1970: 1_719_999_000)
        )
        #expect(fake.requests("POST", "/machine-identity").count == 1)
        #expect(fake.requests("GET", "/members").count == 2)
        #expect(configuration.machineIdentity?.registrationToken == nil)
        await fake.stop()
    }

    @Test("expired bootstrap and old unbound configurations fail closed without leaking authority")
    func failClosed() async throws {
        let fake = try await FakeControlServer.start(workspaceID: workspaceID)
        let signer = try MachineIdentitySigner.ephemeral(machineID: machineID, workspaceID: workspaceID)
        let client = RunbloomClient(
            baseURL: fake.baseURL, workspaceID: workspaceID, secret: fake.secret,
            http: .shared, identity: signer
        )
        let configURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: configURL) }
        var expired = try Self.configuration(token: String(repeating: "x", count: 64), expires: "2020-01-01T00:00:00Z")
        try JSONEncoder().encode(expired).write(to: configURL)
        await #expect(throws: MachineIdentityError.self) {
            try await MachineIdentityBootstrap.establish(
                configuration: &expired, client: client, signer: signer,
                configurationPath: configURL.path, now: issuedAt
            )
        }
        #expect(fake.requests.isEmpty)
        #expect(!String(describing: MachineIdentityError.expiredRegistration).contains(String(repeating: "x", count: 64)))
        await fake.stop()
    }

    @Test("a bearer-only legacy workspace configuration cannot start the Runner")
    func legacyConfigurationFailsClosed() throws {
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-workspace-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: configURL) }
        var configuration = try Self.configuration(token: nil)
        configuration.machineIdentity = nil
        try JSONEncoder().encode(configuration).write(to: configURL)

        #expect(throws: MachineConfigurationError.self) {
            try MachineConfiguration.load(environment: ["BLOOM_WORKSPACE_CONFIG": configURL.path])
        }
    }

    private func requestBinding(
        method: HTTPMethod, target: String, machineID: String? = nil, workspaceID: String? = nil,
        timestamp: Int64 = 1_720_000_000, requestID: UUID? = nil, body: Data
    ) -> Data {
        MachineIdentityCanonical.request(MachineIdentityRequestBinding(
            method: method, target: target,
            machineID: CloudMachineID(machineID ?? self.machineID),
            workspaceID: WorkspaceID(workspaceID ?? self.workspaceID), timestamp: timestamp,
            requestID: requestID ?? requestUUID, body: body
        ))
    }

    private static func configuration(
        token: String?, expires: String = "2030-01-01T00:00:00Z"
    ) throws -> MachineConfiguration {
        var identity: [String: Any] = [
            "version": 1, "machine_id": "01jmachine", "key_id": NSNull(),
        ]
        if let token {
            identity["registration_token"] = token
            identity["registration_expires_at"] = expires
        } else {
            identity["registration_token"] = NSNull()
            identity["registration_expires_at"] = NSNull()
        }
        let object: [String: Any] = [
            "workspace_id": "01jworkspace", "issuer": "https://example.test",
            "jwks_url": "https://example.test/jwks", "base_url": "https://example.test",
            "workspace_secret": "secret-for-tests", "allowed_origins": ["https://example.test"],
            "public_url": "https://workspace.example.test", "repository": "spatie/bloom",
            "branch": "main", "base_branch": "main", "name": "Test", "run_setup": false,
            "machine_identity": identity,
        ]
        return try JSONDecoder().decode(
            MachineConfiguration.self, from: JSONSerialization.data(withJSONObject: object)
        )
    }
}
