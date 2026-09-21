import Foundation
import BloomCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

enum MachineIdentityBootstrap {
    static func establish(
        configuration: inout MachineConfiguration,
        client: RunbloomClient,
        signer: MachineIdentitySigner,
        configurationPath: String,
        now: Date = Date()
    ) async throws {
        guard let configured = configuration.machineIdentity else {
            throw MachineIdentityError.invalidConfiguration("machine_identity is absent")
        }
        let current = await signer.descriptor
        let pending = await signer.pendingDescriptor

        if pending != nil {
            do {
                try await client.verifyMachineIdentity()
                try await signer.discardRotation()
                try eraseRegistration(
                    configuration: &configuration, keyID: current.keyID, path: configurationPath
                )
                return
            } catch let error as RunbloomError where error.isInvalidMachineProof {
                do {
                    try await client.verifyMachineIdentity(usingPending: true)
                    try await signer.commitRotation()
                    let committed = await signer.descriptor
                    try eraseRegistration(
                        configuration: &configuration, keyID: committed.keyID, path: configurationPath
                    )
                    return
                } catch let pendingError as RunbloomError where pendingError.isInvalidMachineProof {
                    throw MachineIdentityError.mismatchedKey
                }
            }
        }

        if let keyID = configured.keyID {
            do {
                try await client.verifyMachineIdentity()
            } catch let error as RunbloomError where error.isInvalidMachineProof && keyID != current.keyID {
                throw MachineIdentityError.mismatchedKey
            }
            if configured.registrationToken != nil || keyID != current.keyID {
                try eraseRegistration(
                    configuration: &configuration, keyID: current.keyID, path: configurationPath
                )
            }
            return
        }

        guard let registrationToken = configured.registrationToken else {
            throw MachineIdentityError.invalidConfiguration("the machine is unbound")
        }
        guard let expires = configured.registrationExpiresAt.flatMap(PersonBoundGithubGrantBody.date),
              expires > now else {
            throw MachineIdentityError.expiredRegistration
        }

        // If a registration answer was lost, the persisted key is already live on the server.
        // Probe it before spending the one-time authority again.
        do {
            try await client.verifyMachineIdentity()
        } catch let error as RunbloomError where error.isInvalidMachineProof {
            do {
                _ = try await client.registerMachineIdentity(registrationToken: registrationToken)
            } catch let registrationError as RunbloomError where registrationError.isInvalidMachineProof {
                // The server can have committed registration while its response was lost. This
                // second signed probe is idempotent and uses a new request id.
                try await client.verifyMachineIdentity()
            }
        }
        try eraseRegistration(configuration: &configuration, keyID: current.keyID, path: configurationPath)
    }

    private static func eraseRegistration(
        configuration: inout MachineConfiguration, keyID: MachineIdentityKeyID, path: String
    ) throws {
        configuration.machineIdentity?.registrationToken = nil
        configuration.machineIdentity?.registrationExpiresAt = nil
        configuration.machineIdentity?.keyID = keyID
        let encoded = try JSONEncoder().encode(configuration)
        do {
            try encoded.write(to: URL(fileURLWithPath: path), options: .atomic)
            guard chmod(path, 0o600) == 0 else {
                throw MachineIdentityError.unavailable("workspace configuration permissions could not be restored")
            }
        } catch let error as MachineIdentityError {
            throw error
        } catch {
            throw MachineIdentityError.unavailable("the consumed registration authority could not be erased")
        }
    }
}

private extension RunbloomError {
    var isInvalidMachineProof: Bool {
        if case .refused(401, "invalid_machine_proof", _, _, _) = self { return true }
        return false
    }
}
