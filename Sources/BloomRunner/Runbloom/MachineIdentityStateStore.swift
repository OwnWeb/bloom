import BloomCore
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if os(Linux)
import Glibc
#else
import Darwin
#endif

struct StoredMachineIdentity: Codable, Sendable {
    var version = 1
    var machineID: CloudMachineID
    var privateKey: String
    var pendingPrivateKey: String?

    enum CodingKeys: String, CodingKey {
        case version
        case machineID = "machine_id"
        case privateKey = "private_key"
        case pendingPrivateKey = "pending_private_key"
    }
}

enum MachineIdentityStateStore {
    static let path = "/var/lib/bloom/machine-identity/state.json"

    static func read(from path: String) throws -> StoredMachineIdentity? {
        do {
            return try JSONDecoder().decode(
                StoredMachineIdentity.self, from: Data(contentsOf: URL(fileURLWithPath: path))
            )
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            throw MachineIdentityError.unavailable("root-owned state is unreadable")
        }
    }

    static func install(_ state: StoredMachineIdentity, executable: String, path: String) throws {
        let encoded = try JSONEncoder().encode(state)
        // Tests and development may supply a private temporary path. The production path is only
        // accepted through the root helper, which installs it without putting key bytes in argv.
        if path != Self.path {
            try installRootState(encoded, path: path, owner: getuid(), group: getgid())
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", executable, "machine-identity-install"]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: encoded)
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw MachineIdentityError.unavailable("the privileged state installer refused the update")
            }
        } catch let error as MachineIdentityError {
            throw error
        } catch {
            throw MachineIdentityError.unavailable("the privileged state installer could not run")
        }
    }

    static func runInstaller() -> Int32 {
        #if os(Linux)
        guard getuid() == 0 else { return 1 }
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard input.count <= 4_096,
              let state = try? JSONDecoder().decode(StoredMachineIdentity.self, from: input),
              state.version == 1, !state.machineID.rawValue.isEmpty,
              validPrivateKey(state.privateKey),
              state.pendingPrivateKey.map(validPrivateKey) ?? true,
              let sudoGID = ProcessInfo.processInfo.environment["SUDO_GID"].flatMap(gid_t.init)
        else { return 1 }
        do {
            try installRootState(input, path: path, owner: 0, group: sudoGID)
            return 0
        } catch { return 1 }
        #else
        return 1
        #endif
    }

    private static func validPrivateKey(_ text: String) -> Bool {
        guard let bytes = Base64URL.decode(text) else { return false }
        return (try? Curve25519.Signing.PrivateKey(rawRepresentation: bytes)) != nil
    }

    static func installRootState(_ data: Data, path: String, owner: uid_t, group: gid_t) throws {
        let files = FileManager.default
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try files.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o750])
        guard chmod(directory, 0o750) == 0, chown(directory, owner, group) == 0 else {
            throw MachineIdentityError.unavailable("root-owned state directory permissions could not be set")
        }
        let temporary = directory + "/.state-\(UUID().uuidString.lowercased())"
        do {
            try data.write(to: URL(fileURLWithPath: temporary), options: .withoutOverwriting)
            guard chmod(temporary, 0o640) == 0, chown(temporary, owner, group) == 0 else {
                throw MachineIdentityError.unavailable("root-owned state permissions could not be set")
            }
            if rename(temporary, path) != 0 {
                throw MachineIdentityError.unavailable("root-owned state could not be replaced")
            }
        } catch {
            try? files.removeItem(atPath: temporary)
            throw error
        }
    }
}
