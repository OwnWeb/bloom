import BloomCore
import Foundation
import Synchronization
#if canImport(Glibc)
import Glibc
#endif

struct PersonBoundRuntimeEvidence: Sendable, Hashable {
    var linux: Bool
    var peerCredentials: Bool
    var separateUID: Bool
    var processGroup: Bool
    var cgroup: Bool
    var launchGate: Bool
    var mountMask: Bool
    var descendantCleanup: Bool
    var protectedControlPath: Bool
    var rootAttestation: Bool
    var credentialExchange: Bool
    var staleCleanup: Bool

    var passes: Bool {
        linux && peerCredentials && separateUID && processGroup && cgroup && launchGate && mountMask
            && descendantCleanup && protectedControlPath && rootAttestation && credentialExchange
            && staleCleanup
    }
}

final class PersonBoundRuntimeFoundation: @unchecked Sendable {
    static let capability = "person_bound_github_credentials_v1"

    let registry: PersonBoundProcessRegistry
    let launcher: PersonBoundSandboxLauncher
    let evidence: PersonBoundRuntimeEvidence

    var capabilities: [String] {
        evidence.passes && registry.isHealthy ? [Self.capability] : []
    }

    private init(registry: PersonBoundProcessRegistry, launcher: PersonBoundSandboxLauncher,
                 evidence: PersonBoundRuntimeEvidence) {
        self.registry = registry
        self.launcher = launcher
        self.evidence = evidence
    }

    /// Startup first removes every stale numeric identity, cgroup and home left by a killed Runner.
    /// The live probe then crosses the real launch gate and credential socket, invokes the real root
    /// ancestry attestor, exchanges a rotating grant, proves the Sprite socket mask and leaves a
    /// descendant for checked cleanup. No inferred evidence is advertised.
    static func live(
        executable: String,
        repository: String,
        worktree: String,
        gitExecutable: String,
        ghExecutable: String,
        gitRemoteHTTPSExecutable: String
    ) async -> PersonBoundRuntimeFoundation? {
        #if !os(Linux)
        return nil
        #else
        let files = FileManager.default
        let staticChecks = files.isExecutableFile(atPath: "/usr/bin/sudo")
            && files.isExecutableFile(atPath: "/usr/bin/unshare")
            && files.isExecutableFile(atPath: "/usr/bin/mount")
            && files.isExecutableFile(atPath: gitExecutable)
            && files.isExecutableFile(atPath: ghExecutable)
            && files.isExecutableFile(atPath: gitRemoteHTTPSExecutable)
            && files.fileExists(atPath: "/etc/ssl/certs/ca-certificates.crt")
            && files.fileExists(atPath: "/sys/fs/cgroup/cgroup.controllers")
            && files.fileExists(atPath: "/.sprite/api.sock")
            && controlPathsAreProtected(files)
        guard staticChecks else { return refused("static host checks") }
        guard PersonBoundSandboxCleanup.cleanupStale(executable: executable) else {
            return refused("startup cleanup")
        }

        let registry = PersonBoundProcessRegistry(agentUID: MachineSandbox.agentUID(), teardown: { identity, reservation in
            PersonBoundSandboxCleanup.invoke(
                executable: executable, identity: identity, reservation: reservation
            )
        })
        guard let launcher = try? PersonBoundSandboxLauncher(
            executable: executable, worktree: worktree, registry: registry
        ),
              let reservation = registry.reserve(.bootstrap) else { return refused("launch gate") }
        let attested = Mutex<PersonBoundOperationAttestation?>(nil)
        let exchanges = Mutex(0)
        let broker = PersonBoundCredentialBroker(
            repository: repository, registry: registry,
            operation: { peer, binding, declared in
                let answer = PersonBoundPeerOperation.attest(
                    peer: peer, binding: binding, declared: declared,
                    runnerExecutable: executable
                )
                // The first attestation, not the last. The self-test asks a second time on
                // purpose and that ask must be refused, so keeping the last answer threw away the
                // proof the test exists to collect and reported `attested=false` on a host where
                // the exchange had in fact worked.
                attested.withLock { $0 = $0 ?? answer }
                return answer
            }
        ) { _, operation, _ in
            exchanges.withLock { $0 += 1 }
            guard operation == .ghRead else { throw PersonBoundSelfTestFailure() }
            return PersonBoundGithubCredentials(
                token: "bloom-person-bound-self-test", expiresAt: .distantFuture,
                username: "x-access-token",
                nextGrant: PersonBoundGithubGrant(
                    token: String(repeating: "n", count: 64), expiresAt: .distantFuture, revision: 2
                )
            )
        }
        broker.install(
            PersonBoundGithubGrant(
                token: String(repeating: "p", count: 64), expiresAt: .distantFuture, revision: 1
            ),
            for: reservation
        )
        guard let socket = try? PersonBoundCredentialSocket(
            path: MachineSandbox.credentialV2SocketPath, group: MachineSandbox.sharedGroup,
            handler: { request, peer in await broker.credential(for: request, peer: peer) }
        ) else {
            launcher.close()
            registry.forgetBeforeTeardown(reservation.id)
            return refused("credential socket")
        }

        var environment = Shell.environment()
        environment["BLOOM_REPOSITORY"] = repository
        environment["BLOOM_RUNNER_EXECUTABLE"] = executable
        environment["BLOOM_REAL_GIT"] = gitExecutable
        environment["BLOOM_REAL_GH"] = ghExecutable
        let probe = launcher.prepare(
            AgentLaunch(
                executable: executable, arguments: ["gh-v2", "pr", "view", "1"],
                cwd: "/tmp", environment: environment
            ),
            reservation: reservation
        )
        let process = StreamingProcess(
            executable: probe.launch.executable, arguments: probe.launch.arguments, cwd: probe.launch.cwd,
            environment: probe.launch.environment,
            cleanup: {
                broker.forget(probe.reservation)
                probe.cleanup()
            }
        )
        var output: [String] = []
        do {
            for try await line in process.lines { output.append(line) }
        } catch {
            socket.close()
            launcher.close()
            return refused("sandbox process stream")
        }
        let status = await process.exitStatus
        socket.close()
        let home = MachineSandbox.personBoundHomeRoot + "/" + reservation.id.uuidString.lowercased()
        let cleaned = !files.fileExists(atPath: reservation.cgroup) && !files.fileExists(atPath: home)
        let proof = attested.withLock { $0 }
        let passed = status == 0 && registry.registrationCount == 1 && registry.isHealthy
            && registry.counts.pending == 0 && registry.counts.active == 0 && cleaned
            && proof?.operation == .ghRead && proof?.identity.wrapper.uid == reservation.uid
            && exchanges.withLock { $0 } == 1
        guard passed else {
            launcher.close()
            return refused(
                "live exchange (status=\(status), registrations=\(registry.registrationCount), "
                    + "pending=\(registry.counts.pending), active=\(registry.counts.active), "
                    + "healthy=\(registry.isHealthy), cleaned=\(cleaned), "
                    + "attested=\(proof?.operation == .ghRead), cross_uid=\(proof?.identity.wrapper.uid == reservation.uid), "
                    + "exchanges=\(exchanges.withLock { $0 }), output=\(output.suffix(8)))"
            )
        }
        let evidence = PersonBoundRuntimeEvidence(
            linux: true, peerCredentials: true, separateUID: true, processGroup: true,
            cgroup: true, launchGate: true, mountMask: true, descendantCleanup: true,
            protectedControlPath: true, rootAttestation: true, credentialExchange: true,
            staleCleanup: true
        )
        return PersonBoundRuntimeFoundation(registry: registry, launcher: launcher, evidence: evidence)
        #endif
    }

    static func capabilities(for evidence: PersonBoundRuntimeEvidence) -> [String] {
        evidence.passes ? [capability] : []
    }

    private static func refused(_ reason: String) -> PersonBoundRuntimeFoundation? {
        FileHandle.standardError.write(Data("bloom-runner: person-bound self-test failed: \(reason)\n".utf8))
        return nil
    }

    #if os(Linux)
    private static func controlPathsAreProtected(_ files: FileManager) -> Bool {
        protectedPath(MachineSandbox.personBoundSharedDirectory, files: files, expectedOwner: getuid())
            && protectedPath(MachineSandbox.personBoundCleanConfigDirectory, files: files, expectedOwner: 0)
            && protectedPath(MachineSandbox.personBoundHomeRoot, files: files, expectedOwner: 0)
            && protectedPath(MachineSandbox.personBoundProvenanceRoot, files: files, expectedOwner: 0)
            && protectedPath(MachineSandbox.personBoundCredentialShield, files: files, expectedOwner: 0)
            && ((try? files.contentsOfDirectory(atPath: MachineSandbox.personBoundCleanConfigDirectory))?.isEmpty == true)
    }

    private static func protectedPath(
        _ path: String, files: FileManager, expectedOwner: UInt32
    ) -> Bool {
        guard let attributes = try? files.attributesOfItem(atPath: path),
              let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value,
              let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value else { return false }
        return owner == expectedOwner && mode & 0o022 == 0
    }
    #endif
}

private struct PersonBoundSelfTestFailure: Error {}
