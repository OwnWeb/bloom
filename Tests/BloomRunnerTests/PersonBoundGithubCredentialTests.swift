import Foundation
import Synchronization
import Testing
import BloomCore
@testable import BloomRunner
#if canImport(Glibc)
import Glibc
#endif

@Suite("Person-bound GitHub credentials")
struct PersonBoundGithubCredentialTests {
    @Test("launch registration is synchronous and descendants inherit only the registered lease")
    func launchRegistrationAndDescendants() throws {
        let identities = Mutex<[Int32: PersonBoundProcessIdentity]>([:])
        let tornDown = Mutex<[UUID]>([])
        let registry = PersonBoundProcessRegistry(
            identity: { pid in identities.withLock { $0[pid] } },
            nonce: { "0123456789abcdef0123456789abcdef" },
            identifier: { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! },
            teardown: { _, reservation in
                tornDown.withLock { $0.append(reservation.id) }
                return true
            }
        )
        let reservation = try #require(registry.reserve(.turn(id: "turn-1", userID: "user-1")))
        let leader = PersonBoundProcessIdentity(
            pid: 41, uid: reservation.uid, startTime: 100, cgroup: reservation.cgroup, processGroup: 41
        )
        identities.withLock { $0[41] = leader }

        #expect(registry.reservation(for: .init(pid: 41, uid: reservation.uid)) == nil)
        #expect(registry.register(nonce: reservation.nonce, peer: .init(pid: 41, uid: reservation.uid)) == reservation)
        #expect(registry.reservation(for: .init(pid: 41, uid: reservation.uid)) == reservation)

        identities.withLock {
            $0[42] = .init(pid: 42, uid: reservation.uid, startTime: 101,
                          cgroup: reservation.cgroup, processGroup: 41)
        }
        #expect(registry.reservation(for: .init(pid: 42, uid: reservation.uid)) == reservation)

        registry.forgetBeforeTeardown(reservation.id)
        #expect(registryCountsAreEmpty(registry))
        #expect(registry.reservation(for: .init(pid: 42, uid: reservation.uid)) == nil)
        #expect(tornDown.withLock { $0 } == [reservation.id])
    }

    @Test("PID reuse, UID changes and cgroup moves are refused")
    func pidReuseIsRefused() throws {
        let identities = Mutex<[Int32: PersonBoundProcessIdentity]>([:])
        let registry = PersonBoundProcessRegistry(
            identity: { pid in identities.withLock { $0[pid] } },
            nonce: { "abcdef0123456789abcdef0123456789" }
        )
        let reservation = try #require(registry.reserve(.turn(id: "turn", userID: "user-1")))
        identities.withLock {
            $0[50] = .init(pid: 50, uid: reservation.uid, startTime: 900,
                          cgroup: reservation.cgroup, processGroup: 50)
        }
        #expect(registry.register(nonce: reservation.nonce, peer: .init(pid: 50, uid: reservation.uid)) != nil)

        identities.withLock { $0[50]?.startTime = 901 }
        #expect(registry.reservation(for: .init(pid: 50, uid: reservation.uid)) == nil)
        identities.withLock {
            $0[50]?.startTime = 900
            $0[51] = .init(pid: 51, uid: reservation.uid + 1, startTime: 902,
                          cgroup: reservation.cgroup, processGroup: 50)
            $0[52] = .init(pid: 52, uid: reservation.uid, startTime: 903,
                          cgroup: reservation.cgroup + "-other", processGroup: 50)
        }
        #expect(registry.reservation(for: .init(pid: 51, uid: reservation.uid + 1)) == nil)
        // Sharing the leader's process group is not enough: another launch's cgroup is another
        // launch, whatever group its process sits in.
        #expect(registry.reservation(for: .init(pid: 52, uid: reservation.uid)) == nil)
    }

    @Test("a descendant in a process group of its own is still its launch's")
    func aDetachedDescendantKeepsItsLaunch() throws {
        // **Claude Code runs every Bash command detached, in a new process group**, and this used
        // to require the leader's group, so every `git push` an agent ran was refused as matching
        // no live launch-gate reservation. What makes a process part of a launch is the cgroup the
        // root launcher put it in, which it cannot leave; the group is its own to change.
        let identities = Mutex<[Int32: PersonBoundProcessIdentity]>([:])
        let registry = PersonBoundProcessRegistry(
            agentUID: 1_002,
            identity: { pid in identities.withLock { $0[pid] } },
            nonce: { "abcdef0123456789abcdef0123456789" }
        )
        let reservation = try #require(registry.reserve(.turn(id: "turn", userID: "user-1")))
        identities.withLock {
            $0[60] = .init(pid: 60, uid: 1_002, startTime: 1, cgroup: reservation.cgroup, processGroup: 60)
        }
        #expect(registry.register(nonce: reservation.nonce, peer: .init(pid: 60, uid: 1_002)) != nil)
        identities.withLock {
            $0[61] = .init(pid: 61, uid: 1_002, startTime: 2, cgroup: reservation.cgroup, processGroup: 61)
        }
        #expect(registry.reservation(for: .init(pid: 61, uid: 1_002)) == reservation)

        // And the rest of the binding still holds for it: once the leader is gone, so is the lease.
        identities.withLock { $0[60] = nil }
        #expect(registry.reservation(for: .init(pid: 61, uid: 1_002)) == nil)
    }

    @Test("simultaneous people receive distinct Unix identities and cgroups")
    func simultaneousPeopleAreSeparate() throws {
        let ids = Mutex(1)
        let registry = PersonBoundProcessRegistry(
            nonce: { UUID().uuidString.replacingOccurrences(of: "-", with: "") },
            identifier: {
                ids.withLock { value in
                    defer { value += 1 }
                    return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
                }
            }
        )
        let first = try #require(registry.reserve(.turn(id: "a", userID: "one")))
        let second = try #require(registry.reserve(.turn(id: "b", userID: "two")))
        #expect(first.uid != second.uid)
        #expect(first.cgroup != second.cgroup)
        #expect(first.purpose != second.purpose)
    }

    @Test("with one agent user, every reservation shares its uid and keeps its own cgroup and nonce")
    func oneAgentUserStillSeparatesReservations() throws {
        let registry = PersonBoundProcessRegistry(agentUID: 1_002)
        let first = try #require(registry.reserve(.turn(id: "a", userID: "one")))
        let second = try #require(registry.reserve(.turn(id: "b", userID: "two")))
        #expect(first.uid == 1_002)
        #expect(second.uid == 1_002)
        #expect(first.cgroup != second.cgroup)
        #expect(first.nonce != second.nonce)
        #expect(first.id != second.id)
    }

    @Test("simultaneous members cannot receive each other's rotating credential")
    func simultaneousMemberCredentialsStayBound() async throws {
        let identities = Mutex<[Int32: PersonBoundProcessIdentity]>([:])
        let nonces = Mutex(0)
        let registry = PersonBoundProcessRegistry(
            identity: { pid in identities.withLock { $0[pid] } },
            nonce: { nonces.withLock { value in defer { value += 1 }; return String(repeating: String(value), count: 32) } }
        )
        let first = try #require(registry.reserve(.turn(id: "turn-a", userID: "member-a")))
        let second = try #require(registry.reserve(.turn(id: "turn-b", userID: "member-b")))
        let firstPeer = LocalSocket.Peer(pid: 81, uid: first.uid)
        let secondPeer = LocalSocket.Peer(pid: 82, uid: second.uid)
        identities.withLock {
            $0[81] = .init(pid: 81, uid: first.uid, startTime: 1, cgroup: first.cgroup, processGroup: 81)
            $0[82] = .init(pid: 82, uid: second.uid, startTime: 2, cgroup: second.cgroup, processGroup: 82)
        }
        _ = registry.register(nonce: first.nonce, peer: firstPeer)
        _ = registry.register(nonce: second.nonce, peer: secondPeer)
        let broker = PersonBoundCredentialBroker(
            repository: "spatie/bloom", registry: registry,
            operation: { _, binding, declared in attestation(binding, operation: declared) }
        ) { current, _, _ in
            let marker = String(current.prefix(1))
            return credentials(token: "raw-for-\(marker)", next: marker == "a" ? "c" : "d")
        }
        broker.install(grant("a"), for: first)
        broker.install(grant("b"), for: second)
        let request = PersonBoundCredentialRequest(repository: "spatie/bloom")
        async let firstAnswer = broker.credential(for: request, peer: firstPeer)
        async let secondAnswer = broker.credential(for: request, peer: secondPeer)
        let answers = await (firstAnswer, secondAnswer)
        #expect(answers.0?.token == "raw-for-a")
        #expect(answers.1?.token == "raw-for-b")
    }

    @Test("one rotating grant admits one concurrent exchange and cancellation closes the lease")
    func concurrencyAndCancellation() async throws {
        let fixture = try registeredFixture()
        let gate = CredentialFetchGate()
        let broker = PersonBoundCredentialBroker(
            repository: "spatie/bloom", registry: fixture.registry,
            operation: { _, binding, declared in attestation(binding, operation: declared) },
            requestID: { UUID(uuidString: "11111111-1111-1111-1111-111111111111")! }
        ) { grant, operation, requestID in
            await gate.hold(grant: grant, operation: operation, requestID: requestID)
            try Task.checkCancellation()
            return credentials(token: "raw-one", next: "b")
        }
        broker.install(grant("a"), for: fixture.reservation)
        let request = PersonBoundCredentialRequest(repository: "spatie/bloom")
        let first = Task { await broker.credential(for: request, peer: fixture.peer) }
        await gate.waitUntilHeld()
        let overlapping = await broker.credential(for: request, peer: fixture.peer)
        #expect(overlapping == nil)
        first.cancel()
        await gate.release()
        let cancelled = await first.value
        let afterCancellation = await broker.credential(for: request, peer: fixture.peer)
        let callCount = await gate.calls
        #expect(cancelled == nil)
        #expect(afterCancellation == nil)
        #expect(callCount == 1)
    }

    @Test("one wrapper operation cannot consume the grant returned by its first exchange")
    func oneCredentialPerOperationIdentity() async throws {
        let fixture = try registeredFixture()
        let calls = Mutex(0)
        let broker = PersonBoundCredentialBroker(
            repository: "spatie/bloom", registry: fixture.registry,
            operation: { _, binding, declared in attestation(binding, operation: declared) }
        ) { _, _, _ in
            calls.withLock { $0 += 1 }
            return credentials(token: "raw-once", next: "b")
        }
        broker.install(grant("a"), for: fixture.reservation)
        let request = PersonBoundCredentialRequest(repository: "spatie/bloom")
        let first = await broker.credential(for: request, peer: fixture.peer)
        let second = await broker.credential(for: request, peer: fixture.peer)
        #expect(first?.token == "raw-once")
        #expect(second == nil)
        #expect(calls.withLock { $0 } == 1)
    }

    @Test("a failed teardown permanently disables new reservations")
    func cleanupFailureIsFailClosed() throws {
        let identities = Mutex<[Int32: PersonBoundProcessIdentity]>([:])
        let registry = PersonBoundProcessRegistry(
            identity: { pid in identities.withLock { $0[pid] } },
            nonce: { "0123456789abcdef0123456789abcdef" },
            teardown: { _, _ in false }
        )
        let reservation = try #require(registry.reserve(.turn(id: "turn", userID: "user")))
        identities.withLock {
            $0[41] = .init(
                pid: 41, uid: reservation.uid, startTime: 1,
                cgroup: reservation.cgroup, processGroup: 41
            )
        }
        _ = registry.register(nonce: reservation.nonce, peer: .init(pid: 41, uid: reservation.uid))
        registry.forgetBeforeTeardown(reservation.id)
        #expect(!registry.isHealthy)
        #expect(registry.reserve(.turn(id: "next", userID: "user")) == nil)
    }

    @Test("forgetting an in-flight lease refuses the returned raw token")
    func forgetDuringExchange() async throws {
        let fixture = try registeredFixture()
        let gate = CredentialFetchGate()
        let broker = PersonBoundCredentialBroker(
            repository: "spatie/bloom", registry: fixture.registry,
            operation: { _, binding, declared in attestation(binding, operation: declared) }
        ) { grant, operation, requestID in
            await gate.hold(grant: grant, operation: operation, requestID: requestID)
            return credentials(token: "must-not-cross-teardown", next: "b")
        }
        broker.install(grant("a"), for: fixture.reservation)
        let request = PersonBoundCredentialRequest(repository: "spatie/bloom")
        let exchange = Task { await broker.credential(for: request, peer: fixture.peer) }
        await gate.waitUntilHeld()
        broker.forget(fixture.reservation)
        await gate.release()
        #expect(await exchange.value == nil)
        #expect(await broker.credential(for: request, peer: fixture.peer) == nil)
    }

    @Test("unknown peers, caller identity fields and wrong repositories never reach the server")
    func unknownPeersAreRefused() async throws {
        let fixture = try registeredFixture()
        let calls = Mutex(0)
        let broker = PersonBoundCredentialBroker(
            repository: "spatie/bloom", registry: fixture.registry,
            operation: { _, binding, declared in attestation(binding, operation: declared) }
        ) { _, _, _ in
            calls.withLock { $0 += 1 }
            return credentials(token: "raw", next: "b")
        }
        broker.install(grant("a"), for: fixture.reservation)
        let wrongRepository = await broker.credential(
            for: .init(repository: "other/repo"), peer: fixture.peer
        )
        let wrongPeer = await broker.credential(
            for: .init(repository: "spatie/bloom"),
            peer: .init(pid: fixture.peer.pid + 99, uid: fixture.peer.uid)
        )
        #expect(wrongRepository == nil)
        #expect(wrongPeer == nil)
        let encoded = String(decoding: try JSONEncoder().encode(
            PersonBoundCredentialRequest(repository: "spatie/bloom")
        ), as: UTF8.self)
        // Who is asking is still never in the request: it comes from the kernel, through the
        // socket peer and the launch gate's binding, and a caller naming a chat, a turn or a user
        // would be a caller choosing whose credential to spend.
        #expect(!encoded.contains("chat"))
        #expect(!encoded.contains("turn"))
        #expect(!encoded.contains("user"))
        // **What it is for is in the request now, and this line used to assert the opposite.**
        // The supervisor used to work the operation out by walking the caller's process tree,
        // which needed a capability no Cloud workspace machine grants and a fixed idea of how git
        // spawns its helpers; it refused every private clone for a day. The caller's word is worth
        // what the sandbox is worth, which is what the uid, cgroup and one-time nonce already
        // rest on, and what the credential is ultimately good for is decided by runbloom.app
        // rather than here.
        #expect(encoded.contains("\"operation\":\"git_read\""))
        #expect(calls.withLock { $0 } == 0)
    }

    @Test("a credential with no expiry is held for a bounded time, not thrown away")
    func aCredentialWithoutAnExpiryIsUsable() throws {
        // **This is the answer runbloom.app actually sends**, and requiring `expires_at` made the
        // Runner discard it. GitHub returns an expiry only when the OAuth app has expiring user
        // tokens switched on; with that off there is nothing to send, and every Cloud workspace
        // failed to clone with "fatal: unable to get password from user" and no reason logged
        // anywhere on either side.
        let answered = Data("""
        {
          "credential": {"username": "x-access-token", "token": "a-token-that-does-not-expire"},
          "next_grant": {"token": "\(String(repeating: "n", count: 64))",
                         "expires_at": "2099-01-01T00:00:00Z", "revision": 2}
        }
        """.utf8)
        let body = try JSONDecoder().decode(PersonBoundGithubCredentialsBody.self, from: answered)
        let issued = try #require(body.issued, "a credential with no expiry must still be usable")
        #expect(issued.token == "a-token-that-does-not-expire")
        #expect(issued.expiresAt > Date())
        #expect(issued.expiresAt <= Date().addingTimeInterval(
            PersonBoundGithubCredentialsBody.lifetimeWithoutAnExpiry + 5
        ))

        // An expiry that is sent is still the one used.
        let dated = Data("""
        {
          "credential": {"username": "x-access-token", "token": "t", "expires_at": "2099-01-01T00:00:00Z"},
          "next_grant": {"token": "\(String(repeating: "n", count: 64))",
                         "expires_at": "2099-01-01T00:00:00Z", "revision": 2}
        }
        """.utf8)
        let withDate = try #require(
            try JSONDecoder().decode(PersonBoundGithubCredentialsBody.self, from: dated).issued
        )
        #expect(withDate.expiresAt > Date().addingTimeInterval(365 * 24 * 3_600))
    }

    @Test("grant and token-bearing values redact descriptions and reflection")
    func secretsAreRedacted() {
        let secret = "raw-secret-that-must-not-appear"
        let value = credentials(token: secret, next: "next-secret")
        let rendered = [String(describing: value), String(reflecting: value)]
        #expect(rendered.allSatisfy { !$0.contains(secret) && !$0.contains("next-secret") })
        #expect(!String(reflecting: value.nextGrant).contains("next-secret"))
    }

    @Test("the umbrella capability is all or nothing")
    func umbrellaCapability() {
        let passing = PersonBoundRuntimeEvidence(
            linux: true, peerCredentials: true, separateUID: true, processGroup: true,
            cgroup: true, launchGate: true, mountMask: true, descendantCleanup: true,
            protectedControlPath: true, rootAttestation: true, credentialExchange: true,
            staleCleanup: true
        )
        #expect(PersonBoundRuntimeFoundation.capabilities(for: passing) == ["person_bound_github_credentials_v1"])
        var failing = passing
        failing.descendantCleanup = false
        #expect(PersonBoundRuntimeFoundation.capabilities(for: failing).isEmpty)
    }

    #if os(Linux)
    @Test("the privileged Linux foundation proves the complete live sandbox contract", .timeLimit(.minutes(2)))
    func liveLinuxFoundation() async throws {
        guard ProcessInfo.processInfo.environment["BLOOM_PERSON_BOUND_INTEGRATION"] == "1" else { return }
        let executable = try #require(ProcessInfo.processInfo.environment["BLOOM_RUNNER_TEST_EXECUTABLE"])
        let worktree = try #require(ProcessInfo.processInfo.environment["BLOOM_WORKTREE"])
        let git = "/usr/bin/git"
        let gh = "/usr/bin/gh"
        let remoteHTTPS = try #require(PersonBoundGitCommand.gitRemoteHTTPSExecutable(gitExecutable: git))
        let foundation = try #require(await PersonBoundRuntimeFoundation.live(
            executable: executable, repository: "spatie/bloom", worktree: worktree,
            gitExecutable: git, ghExecutable: gh, gitRemoteHTTPSExecutable: remoteHTTPS
        ))
        if let stalePID = ProcessInfo.processInfo.environment["BLOOM_PERSON_BOUND_STALE_PID"] {
            #expect(!FileManager.default.fileExists(atPath: "/proc/\(stalePID)"))
            #expect(!FileManager.default.fileExists(
                atPath: "/sys/fs/cgroup/bloom-person-bound/stale-proof"
            ))
            #expect(!FileManager.default.fileExists(
                atPath: MachineSandbox.personBoundHomeRoot + "/stale-proof"
            ))
            #expect(!FileManager.default.fileExists(
                atPath: MachineSandbox.personBoundProvenanceRoot + "/stale-proof"
            ))
        }
        #expect(foundation.capabilities == [PersonBoundRuntimeFoundation.capability])
        #expect(foundation.registry.counts.pending == 0)
        #expect(foundation.registry.counts.active == 0)

        let operation = Mutex<PersonBoundGithubOperation?>(nil)
        let fetches = Mutex(0)
        let broker = PersonBoundCredentialBroker(
            repository: "spatie/bloom", registry: foundation.registry,
            operation: { peer, binding, declared in
                PersonBoundPeerOperation.attest(
                    peer: peer, binding: binding, declared: declared,
                    runnerExecutable: executable
                )
            }
        ) { _, requested, _ in
            fetches.withLock { $0 += 1 }
            operation.withLock { $0 = requested }
            return credentials(token: "raw-token-used-once", next: "n")
        }
        let socket = try PersonBoundCredentialSocket(
            path: MachineSandbox.credentialV2SocketPath, group: MachineSandbox.sharedGroup
        ) { request, peer in
            await broker.credential(for: request, peer: peer)
        }
        defer { socket.close() }
        let reservation = try #require(foundation.registry.reserve(.turn(id: "proof", userID: "proof")))
        broker.install(grant("g"), for: reservation)
        var environment = ProcessInfo.processInfo.environment
        environment["BLOOM_REPOSITORY"] = "spatie/bloom"
        environment["BLOOM_RUNNER_EXECUTABLE"] = executable
        environment["BLOOM_REAL_GIT"] = git
        environment["BLOOM_REAL_GH"] = gh
        environment["BLOOM_CREDENTIAL_SOCKET_V2"] = MachineSandbox.credentialV2SocketPath
        let prepared = foundation.launcher.prepare(
            AgentLaunch(
                executable: "/usr/local/bin/person-bound-trusted-launch", arguments: [executable],
                cwd: "/tmp", environment: environment
            ),
            reservation: reservation
        )
        let process = StreamingProcess(
            executable: prepared.launch.executable, arguments: prepared.launch.arguments,
            cwd: prepared.launch.cwd, environment: prepared.launch.environment,
            cleanup: {
                broker.forget(prepared.reservation)
                prepared.cleanup()
            }
        )
        var processLines: [String] = []
        for try await line in process.lines { processLines.append(line) }
        let processStatus = await process.exitStatus
        #expect(processStatus == 0, "gh status: \(processStatus), output: \(processLines)")
        #expect(operation.withLock { $0 } == .ghRead)
        #expect(fetches.withLock { $0 } == 1)
        #expect(foundation.registry.counts.pending == 0)
        #expect(foundation.registry.counts.active == 0)

        let scriptReservation = try #require(foundation.registry.reserve(.turn(id: "script", userID: "proof")))
        broker.install(grant("s"), for: scriptReservation)
        let scripted = foundation.launcher.prepare(
            AgentLaunch(
                executable: "/bin/sh",
                arguments: [worktree + "/Tests/fixtures/person-bound-repository-operation.sh"],
                cwd: worktree, environment: environment
            ),
            reservation: scriptReservation
        )
        let scriptProcess = StreamingProcess(
            executable: scripted.launch.executable, arguments: scripted.launch.arguments,
            cwd: scripted.launch.cwd, environment: scripted.launch.environment,
            cleanup: {
                broker.forget(scripted.reservation)
                scripted.cleanup()
            }
        )
        for try await _ in scriptProcess.lines {}
        #expect(await scriptProcess.exitStatus != 0)
        #expect(fetches.withLock { $0 } == 1, "a repository script must never reach credential exchange")

        foundation.launcher.close()
        socket.close()

        let gitProof = "/tmp/bloom-person-bound-git-proof-\(UUID().uuidString.lowercased())"
        try FileManager.default.createDirectory(atPath: gitProof, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: gitProof) }
        #expect(try await Shell.run("git", ["init", "-q"], cwd: gitProof).status == 0)
        let canonical = "https://github.com/spatie/bloom.git"
        #expect(try await Shell.run(
            "git", ["config", "--local", "url.https://attacker.invalid/.insteadOf", canonical], cwd: gitProof
        ).status == 0)
        let gitRegistry = PersonBoundProcessRegistry(
            firstUID: 240_000,
            teardown: { identity, reservation in
                PersonBoundSandboxCleanup.invoke(
                    executable: executable, identity: identity, reservation: reservation
                )
            }
        )
        let gitLauncher = try PersonBoundSandboxLauncher(
            executable: executable, worktree: gitProof, registry: gitRegistry
        )
        let gitReservation = try #require(gitRegistry.reserve(.turn(id: "git", userID: "proof")))
        var gitEnvironment = environment
        gitEnvironment["BLOOM_REAL_GIT_REMOTE_HTTPS"] = remoteHTTPS
        let gitPrepared = gitLauncher.prepare(
            AgentLaunch(
                executable: executable,
                arguments: ["git-v2", "ls-remote", "--get-url", canonical],
                cwd: gitProof, environment: gitEnvironment
            ),
            reservation: gitReservation
        )
        let gitProcess = StreamingProcess(
            executable: gitPrepared.launch.executable, arguments: gitPrepared.launch.arguments,
            cwd: gitPrepared.launch.cwd, environment: gitPrepared.launch.environment,
            cleanup: { gitPrepared.cleanup() }
        )
        var gitLines: [String] = []
        for try await line in gitProcess.lines { gitLines.append(line) }
        let gitStatus = await gitProcess.exitStatus
        #expect(gitStatus == 0, "Git status: \(gitStatus), output: \(gitLines)")
        #expect(gitLines == [canonical])
        gitLauncher.close()

        let owner = Process()
        owner.executableURL = URL(fileURLWithPath: "/bin/sleep")
        owner.arguments = ["30"]
        try owner.run()
        let ownerIdentity = try #require(await waitForIdentity(Int32(owner.processIdentifier)))
        let deathRegistry = PersonBoundProcessRegistry(firstUID: 250_000, teardown: { identity, reservation in
            PersonBoundSandboxCleanup.invoke(
                executable: executable, identity: identity, reservation: reservation
            )
        })
        let deathLauncher = try PersonBoundSandboxLauncher(
            executable: executable, worktree: worktree, registry: deathRegistry,
            supervisor: ownerIdentity
        )
        defer { deathLauncher.close() }
        let deathReservation = try #require(deathRegistry.reserve(.turn(id: "death", userID: "proof")))
        let deathPrepared = deathLauncher.prepare(
            AgentLaunch(executable: "/bin/sleep", arguments: ["30"], cwd: "/tmp", environment: [:]),
            reservation: deathReservation
        )
        let deathProcess = StreamingProcess(
            executable: deathPrepared.launch.executable, arguments: deathPrepared.launch.arguments,
            cwd: deathPrepared.launch.cwd, environment: deathPrepared.launch.environment,
            cleanup: { deathPrepared.cleanup() }
        )
        let deathReading = Task {
            var lines: [String] = []
            for try await line in deathProcess.lines { lines.append(line) }
            return lines
        }
        guard await waitForRegistration(deathRegistry) else {
            let deathLines = try await deathReading.value
            let deathStatus = await deathProcess.exitStatus
            Issue.record(
                "registration counts: \(deathRegistry.counts), cgroup exists: \(FileManager.default.fileExists(atPath: deathReservation.cgroup)), status: \(deathStatus), output: \(deathLines)"
            )
            return
        }
        let members = try String(contentsOfFile: deathReservation.cgroup + "/cgroup.procs", encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        #expect(!members.isEmpty)
        #expect(kill(Int32(owner.processIdentifier), SIGKILL) == 0)
        let deathLines = try await deathReading.value
        let deathStatus = await deathProcess.exitStatus
        #expect(deathStatus != 0, "supervised process status: \(deathStatus), output: \(deathLines)")
        #expect(members.allSatisfy { !FileManager.default.fileExists(atPath: "/proc/\($0)") })
        #expect(deathRegistry.isHealthy)
        #expect(PersonBoundSandboxCleanup.cleanupStale(executable: executable))
    }
    #endif
}

#if os(Linux)
private func waitForIdentity(_ pid: Int32) async -> PersonBoundProcessIdentity? {
    for _ in 0..<200 {
        if let identity = PersonBoundProcIdentity.read(pid) { return identity }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return nil
}

private func waitForRegistration(_ registry: PersonBoundProcessRegistry) async -> Bool {
    for _ in 0..<200 {
        if registry.counts.active == 1 { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}
#endif

private func registryCountsAreEmpty(_ registry: PersonBoundProcessRegistry) -> Bool {
    registry.counts.active == 0 && registry.counts.pending == 0
}

private func grant(_ marker: String) -> PersonBoundGithubGrant {
    PersonBoundGithubGrant(token: String(repeating: marker, count: 64), expiresAt: .distantFuture, revision: 1)
}

private func credentials(token: String, next: String) -> PersonBoundGithubCredentials {
    PersonBoundGithubCredentials(token: token, expiresAt: .distantFuture, username: "x-access-token", nextGrant: grant(next))
}

private func registeredFixture() throws -> (
    registry: PersonBoundProcessRegistry,
    reservation: PersonBoundProcessRegistry.Reservation,
    peer: LocalSocket.Peer
) {
    let identities = Mutex<[Int32: PersonBoundProcessIdentity]>([:])
    let registry = PersonBoundProcessRegistry(
        identity: { pid in identities.withLock { $0[pid] } },
        nonce: { "0123456789abcdef0123456789abcdef" }
    )
    let reservation = try #require(registry.reserve(.turn(id: "turn", userID: "user")))
    let peer = LocalSocket.Peer(pid: 71, uid: reservation.uid)
    identities.withLock {
        $0[peer.pid] = .init(pid: peer.pid, uid: peer.uid, startTime: 7,
                            cgroup: reservation.cgroup, processGroup: peer.pid)
    }
    _ = registry.register(nonce: reservation.nonce, peer: peer)
    return (registry, reservation, peer)
}

private func attestation(
    _ binding: PersonBoundProcessRegistry.Binding,
    operation: PersonBoundGithubOperation
) -> PersonBoundOperationAttestation {
    PersonBoundOperationAttestation(
        operation: operation,
        identity: PersonBoundOperationIdentity(wrapper: binding.peerIdentity, operation: operation)
    )
}

private actor CredentialFetchGate {
    private var arrival: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private(set) var calls = 0

    func hold(grant: String, operation: PersonBoundGithubOperation, requestID: UUID) async {
        calls += 1
        arrival?.resume()
        arrival = nil
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilHeld() async {
        if calls > 0 { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
