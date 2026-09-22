import BloomCore
import Foundation
#if canImport(Glibc)
import Glibc
#endif

struct PersonBoundOperationIdentity: Codable, Sendable, Hashable {
    var wrapper: PersonBoundProcessIdentity
    var operation: PersonBoundGithubOperation
}

struct PersonBoundOperationAttestation: Codable, Sendable, Hashable {
    var operation: PersonBoundGithubOperation
    var identity: PersonBoundOperationIdentity
}

/// Classifies a credential request from a complete root-observed command ancestry. Every process
/// in the chain is read twice and then re-read after classification, including PID, UID, start
/// time, cgroup and process group. No request or sandbox environment chooses the operation.
enum PersonBoundPeerOperation {
    struct Command: Codable, Sendable, Equatable {
        var identity: PersonBoundProcessIdentity
        var parentPID: Int32
        var executable: String
        var arguments: [String]
        var cwd: String
        var environment: [String: String]
    }

    typealias Read = @Sendable (Int32) -> Command?
    typealias Provenance = @Sendable (PersonBoundProcessIdentity) -> Bool

    static func resolve(
        peer: LocalSocket.Peer,
        peerIdentity: PersonBoundProcessIdentity,
        leaderIdentity: PersonBoundProcessIdentity,
        repository: String,
        worktree: String,
        cleanConfigDirectory: String,
        runnerExecutable: String,
        gitExecutable: String,
        gitRemoteHTTPSExecutable: String,
        provenance: Provenance = { _ in true },
        read: Read = { liveCommand($0) }
    ) -> PersonBoundOperationAttestation? {
        let runner = canonical(runnerExecutable)
        let git = canonical(gitExecutable)
        let remoteHTTPS = canonical(gitRemoteHTTPSExecutable)
        var observed: [Int32: Command] = [:]

        func stable(_ pid: Int32) -> Command? {
            guard let first = read(pid), first.identity.pid == pid,
                  let second = read(pid), second == first else { return nil }
            observed[pid] = first
            return first
        }

        guard peerIdentity.pid == peer.pid, peerIdentity.uid == peer.uid,
              let caller = stable(peer.pid), caller.identity == peerIdentity,
              sameReservation(caller.identity, leaderIdentity),
              canonical(caller.executable) == runner else { return nil }
        let callerArguments = argumentsAfterExecutable(caller, executable: runner)
        guard let callerCommand = callerArguments.first else { return nil }

        let operation: PersonBoundGithubOperation
        let wrapper: Command
        switch callerCommand {
        case "gh-v2":
            guard let invocation = PersonBoundGitCommand.ghInvocation(
                Array(callerArguments.dropFirst()), repository: repository
            ), let classified = invocation.operation else { return nil }
            operation = classified
            wrapper = caller
        case "git-credential-v2":
            guard Array(callerArguments.dropFirst()) == ["get"],
                  let immediateParent = stable(caller.parentPID),
                  sameReservation(immediateParent.identity, leaderIdentity),
                  let transport = credentialTransport(
                      parent: immediateParent, remoteHTTPS: remoteHTTPS, stable: stable
                  ),
                  transport.arguments.count == 3,
                  exactURL(transport.arguments[2], repository: repository),
                  sameReservation(transport.identity, leaderIdentity),
                  let gitProcess = stable(transport.parentPID),
                  canonical(gitProcess.executable) == git,
                  sameReservation(gitProcess.identity, leaderIdentity),
                  let candidate = stable(gitProcess.parentPID),
                  canonical(candidate.executable) == runner,
                  sameReservation(candidate.identity, leaderIdentity),
                  argumentsAfterExecutable(candidate, executable: runner).first == "git-v2",
                  let invocation = PersonBoundGitCommand.gitInvocation(
                      Array(argumentsAfterExecutable(candidate, executable: runner).dropFirst()),
                      repository: repository
                  ), let classified = invocation.operation,
                  argumentsAfterExecutable(gitProcess, executable: git) == PersonBoundGitCommand.networkArguments(
                      for: invocation, repository: repository, runnerExecutable: runnerExecutable,
                      gitRemoteHTTPSExecutable: gitRemoteHTTPSExecutable
                  ),
                  PersonBoundGitCommand.networkEnvironmentIsClean(
                      gitProcess.environment, cleanConfigDirectory: cleanConfigDirectory
                  )
            else { return nil }
            operation = classified
            wrapper = candidate
        default:
            return nil
        }

        guard provenance(wrapper.identity), validateAncestors(
            from: wrapper, through: leaderIdentity, worktree: worktree,
            stable: stable
        ) else { return nil }

        for (pid, command) in observed {
            guard read(pid) == command else { return nil }
        }
        guard provenance(wrapper.identity) else { return nil }
        let identity = PersonBoundOperationIdentity(wrapper: wrapper.identity, operation: operation)
        return PersonBoundOperationAttestation(operation: operation, identity: identity)
    }

    static func attest(
        peer: LocalSocket.Peer,
        binding: PersonBoundProcessRegistry.Binding,
        repository: String,
        worktree: String,
        runnerExecutable: String,
        gitExecutable: String,
        gitRemoteHTTPSExecutable: String
    ) -> PersonBoundOperationAttestation? {
        #if !os(Linux)
        return nil
        #else
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "-E", runnerExecutable, "sandbox-peer-operation"]
        process.environment = attestationEnvironment(
            peer: peer, binding: binding, repository: repository, worktree: worktree,
            runnerExecutable: runnerExecutable, gitExecutable: gitExecutable,
            gitRemoteHTTPSExecutable: gitRemoteHTTPSExecutable
        )
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return try JSONDecoder().decode(
                PersonBoundOperationAttestation.self,
                from: output.fileHandleForReading.readDataToEndOfFile()
            )
        } catch {
            return nil
        }
        #endif
    }

    static func runAttestor(environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        #if !os(Linux)
        return 1
        #else
        guard getuid() == 0 else { return attestorRefused("not root") }
        guard let peer = identity(prefix: "BLOOM_PERSON_BOUND_PEER", environment: environment),
              let leader = identity(prefix: "BLOOM_PERSON_BOUND_LEADER", environment: environment),
              let repository = environment["BLOOM_PERSON_BOUND_REPOSITORY"],
              let worktree = environment["BLOOM_PERSON_BOUND_WORKTREE"],
              let runner = environment["BLOOM_PERSON_BOUND_RUNNER"],
              let git = environment["BLOOM_PERSON_BOUND_GIT"],
              let remoteHTTPS = environment["BLOOM_PERSON_BOUND_GIT_REMOTE_HTTPS"],
              let cleanConfig = environment["BLOOM_PERSON_BOUND_CLEAN_CONFIG"],
              let provenanceDirectory = provenanceDirectory(environment)
        else { return attestorRefused("missing identity or machine configuration") }
        guard rootOwnedExecutablePath(runner), rootOwnedExecutablePath(git),
              rootOwnedExecutablePath(remoteHTTPS) else {
            return attestorRefused("untrusted executable path")
        }
        guard rootOwnedEmptyDirectory(cleanConfig) else {
            return attestorRefused("untrusted network configuration")
        }
        let attestation = resolve(
            peer: .init(pid: peer.pid, uid: peer.uid), peerIdentity: peer,
            leaderIdentity: leader, repository: repository, worktree: worktree,
            cleanConfigDirectory: cleanConfig, runnerExecutable: runner,
            gitExecutable: git, gitRemoteHTTPSExecutable: remoteHTTPS,
            provenance: { provenanceIsTrusted($0, directory: provenanceDirectory) }
        )
        guard let attestation else { return attestorRefused("process ancestry") }
        guard let encoded = try? JSONEncoder().encode(attestation) else {
            return attestorRefused("answer encoding")
        }
        FileHandle.standardOutput.write(encoded)
        return 0
        #endif
    }

    static func liveCommand(_ pid: Int32, root: String = "/proc") -> Command? {
        guard pid > 1, let before = PersonBoundProcIdentity.read(pid, root: root),
              let stat = try? String(contentsOfFile: root + "/\(pid)/stat", encoding: .utf8),
              let close = stat.lastIndex(of: ")"),
              let commandLine = try? Data(contentsOf: URL(fileURLWithPath: root + "/\(pid)/cmdline")),
              let environmentData = try? Data(contentsOf: URL(fileURLWithPath: root + "/\(pid)/environ")),
              let executable = try? FileManager.default.destinationOfSymbolicLink(atPath: root + "/\(pid)/exe"),
              let cwd = try? FileManager.default.destinationOfSymbolicLink(atPath: root + "/\(pid)/cwd"),
              let after = PersonBoundProcIdentity.read(pid, root: root), before == after
        else { return nil }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        guard fields.count > 1, let parentPID = Int32(fields[1]) else { return nil }
        let arguments = commandLine.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        guard !arguments.isEmpty else { return nil }
        var environment: [String: String] = [:]
        for field in environmentData.split(separator: 0) {
            let value = String(decoding: field, as: UTF8.self)
            guard let separator = value.firstIndex(of: "=") else { continue }
            environment[String(value[..<separator])] = String(value[value.index(after: separator)...])
        }
        return Command(
            identity: before, parentPID: parentPID, executable: executable,
            arguments: arguments, cwd: cwd, environment: environment
        )
    }

    private static func credentialTransport(
        parent: Command, remoteHTTPS: String, stable: (Int32) -> Command?
    ) -> Command? {
        if canonical(parent.executable) == remoteHTTPS { return parent }
        let shells = ["/bin/sh", "/usr/bin/sh", "/bin/dash", "/usr/bin/dash"].map(canonical)
        guard shells.contains(canonical(parent.executable)),
              let transport = stable(parent.parentPID), canonical(transport.executable) == remoteHTTPS
        else { return nil }
        return transport
    }

    private static func validateAncestors(
        from wrapper: Command, through leader: PersonBoundProcessIdentity,
        worktree: String, stable: (Int32) -> Command?
    ) -> Bool {
        var command = wrapper
        var visited: Set<Int32> = []
        for _ in 0..<64 {
            guard visited.insert(command.identity.pid).inserted,
                  sameReservation(command.identity, leader),
                  !repositoryControlled(command, worktree: worktree) else { return false }
            if command.identity == leader { return true }
            guard let parent = stable(command.parentPID) else { return false }
            command = parent
        }
        return false
    }

    static func repositoryControlled(_ command: Command, worktree: String) -> Bool {
        let root = canonical(worktree)
        if isInside(canonical(command.executable), root: root) { return true }
        let name = URL(fileURLWithPath: command.executable).lastPathComponent
        let repositoryDrivers = [
            "make", "gmake", "ninja", "just", "task", "npm", "npx", "pnpm", "yarn", "bun",
            "cargo", "gradle", "gradlew", "mvn", "swift", "xcodebuild",
        ]
        if repositoryDrivers.contains(name), isInside(canonical(command.cwd), root: root) { return true }
        let interpreters = ["sh", "bash", "dash", "zsh", "python", "python3", "ruby", "perl", "node"]
        let isInterpreter = interpreters.contains(name)
        guard isInterpreter else { return false }
        for argument in command.arguments.dropFirst() where !argument.hasPrefix("-") {
            if argument.contains(root + "/") || argument.contains("./") || argument.contains(".bloom/") {
                return true
            }
            let candidate = argument.hasPrefix("/")
                ? canonical(argument)
                : canonical(URL(fileURLWithPath: command.cwd).appendingPathComponent(argument).path)
            if isInside(candidate, root: root), FileManager.default.fileExists(atPath: candidate) { return true }
        }
        return false
    }

    private static func isInside(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func argumentsAfterExecutable(_ command: Command, executable: String) -> [String] {
        guard let first = command.arguments.first else { return [] }
        let expectedName = URL(fileURLWithPath: executable).lastPathComponent
        let firstName = URL(fileURLWithPath: first).lastPathComponent
        if firstName == expectedName { return Array(command.arguments.dropFirst()) }
        return command.arguments
    }

    private static func sameReservation(
        _ identity: PersonBoundProcessIdentity, _ leader: PersonBoundProcessIdentity
    ) -> Bool {
        identity.uid == leader.uid && identity.cgroup == leader.cgroup
            && identity.processGroup == leader.processGroup
    }

    private static func attestationEnvironment(
        peer: LocalSocket.Peer,
        binding: PersonBoundProcessRegistry.Binding,
        repository: String,
        worktree: String,
        runnerExecutable: String,
        gitExecutable: String,
        gitRemoteHTTPSExecutable: String
    ) -> [String: String] {
        var environment = [
            "PATH": "/usr/bin:/bin",
            "BLOOM_PERSON_BOUND_REPOSITORY": repository,
            "BLOOM_PERSON_BOUND_WORKTREE": worktree,
            "BLOOM_PERSON_BOUND_RUNNER": runnerExecutable,
            "BLOOM_PERSON_BOUND_GIT": gitExecutable,
            "BLOOM_PERSON_BOUND_GIT_REMOTE_HTTPS": gitRemoteHTTPSExecutable,
            "BLOOM_PERSON_BOUND_CLEAN_CONFIG": MachineSandbox.personBoundCleanConfigDirectory,
            "BLOOM_PERSON_BOUND_PROVENANCE_ROOT": MachineSandbox.personBoundProvenanceRoot,
            "BLOOM_PERSON_BOUND_RESERVATION": binding.reservation.id.uuidString.lowercased(),
        ]
        put(binding.peerIdentity, prefix: "BLOOM_PERSON_BOUND_PEER", into: &environment)
        put(binding.leaderIdentity, prefix: "BLOOM_PERSON_BOUND_LEADER", into: &environment)
        environment["BLOOM_PERSON_BOUND_PEER_PID"] = String(peer.pid)
        environment["BLOOM_PERSON_BOUND_PEER_UID"] = String(peer.uid)
        return environment
    }

    private static func put(
        _ identity: PersonBoundProcessIdentity, prefix: String,
        into environment: inout [String: String]
    ) {
        environment[prefix + "_PID"] = String(identity.pid)
        environment[prefix + "_UID"] = String(identity.uid)
        environment[prefix + "_START"] = String(identity.startTime)
        environment[prefix + "_CGROUP"] = identity.cgroup
        environment[prefix + "_PROCESS_GROUP"] = String(identity.processGroup)
    }

    private static func identity(prefix: String, environment: [String: String]) -> PersonBoundProcessIdentity? {
        guard let pid = environment[prefix + "_PID"].flatMap(Int32.init),
              let uid = environment[prefix + "_UID"].flatMap(UInt32.init),
              let start = environment[prefix + "_START"].flatMap(UInt64.init),
              let cgroup = environment[prefix + "_CGROUP"],
              let processGroup = environment[prefix + "_PROCESS_GROUP"].flatMap(Int32.init)
        else { return nil }
        return PersonBoundProcessIdentity(
            pid: pid, uid: uid, startTime: start, cgroup: cgroup, processGroup: processGroup
        )
    }

    private static func exactURL(_ value: String, repository: String) -> Bool {
        let lower = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let repo = repository.lowercased()
        return lower == "https://github.com/\(repo)" || lower == "https://github.com/\(repo).git"
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func attestorRefused(_ reason: String) -> Int32 {
        FileHandle.standardError.write(Data("bloom-runner: person-bound root attestation refused: \(reason)\n".utf8))
        return 1
    }

    #if os(Linux)
    private static func provenanceDirectory(_ environment: [String: String]) -> String? {
        guard environment["BLOOM_PERSON_BOUND_PROVENANCE_ROOT"] == MachineSandbox.personBoundProvenanceRoot,
              let reservation = environment["BLOOM_PERSON_BOUND_RESERVATION"],
              UUID(uuidString: reservation) != nil else { return nil }
        let path = MachineSandbox.personBoundProvenanceRoot + "/" + reservation.lowercased()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue,
              rootOwnsPath(path) else { return nil }
        return path
    }

    private static func provenanceIsTrusted(
        _ identity: PersonBoundProcessIdentity, directory: String
    ) -> Bool {
        let path = directory + "/\(identity.pid)-\(identity.startTime)"
        guard rootOwnsPath(path), let value = try? String(contentsOfFile: path, encoding: .utf8) else {
            FileHandle.standardError.write(Data(
                "bloom-runner: person-bound root attestation refused: missing protected provenance\n".utf8
            ))
            return false
        }
        if value != "trusted\n" {
            FileHandle.standardError.write(Data(
                "bloom-runner: person-bound root attestation refused: \(value.trimmingCharacters(in: .whitespacesAndNewlines)) provenance\n".utf8
            ))
        }
        return value == "trusted\n"
    }

    /// `PersonBoundTrustedExecutable` holds this rule now, so the attestor and the host checks
    /// that decide whether the Runner starts cannot drift apart.
    private static func rootOwnedExecutablePath(_ path: String) -> Bool {
        PersonBoundTrustedExecutable.isTrusted(path)
    }

    private static func rootOwnedEmptyDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &directory),
              directory.boolValue, rootOwnsPath(path),
              (try? FileManager.default.contentsOfDirectory(atPath: path))?.isEmpty == true else { return false }
        return true
    }

    private static func rootOwnsPath(_ path: String) -> Bool {
        PersonBoundTrustedExecutable.rootOwnsPath(path)
    }
    #endif
}
