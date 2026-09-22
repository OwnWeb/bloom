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

    /// What the root supervisor saw a process exec, written down at the exec stop and read back
    /// when a credential is asked for.
    ///
    /// **Recorded rather than re-read, because re-reading is not allowed here.** `/proc/<pid>/exe`
    /// and `environ` need CAP_SYS_PTRACE to read across uids, and a Cloud workspace's machine
    /// grants root every other capability and not that one, so the attestor could inspect nothing
    /// and refused every request. It is also the better of the two: the supervisor traces every
    /// exec, so it writes this at the one instant the fact is true, and rewrites it if the process
    /// execs again, where inspecting a live process has to be done twice and compared in the hope
    /// that nothing moved in between.
    struct ProvenanceRecord: Codable, Sendable {
        var status: String
        var command: Command
    }

    typealias Read = @Sendable (Int32) -> Command?
    typealias Provenance = @Sendable (PersonBoundProcessIdentity) -> Bool

    /// Who is asking, and for what.
    ///
    /// **This used to walk the caller's process tree** from the credential helper up through
    /// git-remote-https, git and the runner's own wrapper, reading `/proc/<pid>/exe`, `cwd` and
    /// `environ` of each, through a root helper spawned under sudo. It refused every Cloud
    /// workspace for a day. It needed CAP_SYS_PTRACE, which a machine does not grant; it could not
    /// read a process that had hidden itself to protect a token; and it encoded a shape for git's
    /// helpers that git does not promise and does not keep. Four different links broke, one at a
    /// time, each behind the last, and the whole of it was re-deriving something the launch gate
    /// already knew.
    ///
    /// What is left is two questions, and neither is about the shape of a process tree.
    ///
    /// **Who is asking** is the launch gate's answer: `registry.binding(for:)` has already checked
    /// the uid the kernel reports for the socket peer, the uid and cgroup of the reservation the
    /// one-time launch nonce opened, the process group, and that the sandbox leader is still alive
    /// and unchanged. What it is for comes from the caller, for the reasons on
    /// `PersonBoundCredentialRequest.operation`.
    ///
    /// **Whether it may ask at all** is one file: the provenance record the sandbox supervisor
    /// wrote when it watched this process exec. That supervisor already traces every exec in the
    /// reservation, already marks anything running the repository's own code as tainted, and
    /// already inherits that taint to children, defaulting to tainted. So the question "is this a
    /// checkout's setup script trying to take the person's GitHub credential" is answered by
    /// reading what was recorded, rather than by re-deriving it from `/proc` at the moment of the
    /// request, which is what could not be done without a capability no machine grants.
    static func attest(
        peer: LocalSocket.Peer,
        binding: PersonBoundProcessRegistry.Binding,
        declared: PersonBoundGithubOperation,
        runnerExecutable: String
    ) -> PersonBoundOperationAttestation? {
        guard binding.peerIdentity.pid == peer.pid, binding.peerIdentity.uid == peer.uid else {
            return nil
        }
        #if os(Linux)
        /*
         * **Asked as root, because the Runner is not root and this cannot be read from here.**
         * The Runner serves as the machine's own user and every sandboxed process belongs to a
         * person's uid, so it may read their `/proc/<pid>/stat` and nothing else: `exe` and `cwd`
         * go through `ptrace_may_access`, which admits a reader on a uid match and the Runner
         * never matches. `liveCommandAsOwner` becomes that uid to read, and only root may.
         */
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "-E", runnerExecutable, "sandbox-peer-operation"]
        process.environment = attestationEnvironment(peer: peer, binding: binding)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
        } catch {
            return nil
        }
        #endif
        let identity = PersonBoundOperationIdentity(wrapper: binding.peerIdentity, operation: declared)

        return PersonBoundOperationAttestation(operation: declared, identity: identity)
    }

    /// The root half of `attest`, and the whole of what it does is read one file.
    ///
    /// **It is a separate process only because of a file mode.** The record below is written by
    /// the sandbox supervisor as root and left `0400 root`, so the sandbox user cannot forge one
    /// and the Runner, which serves as the machine's own unprivileged user, cannot read one. That
    /// is the entire reason for the `sudo` hop; nothing here needs a capability, traces a process,
    /// or looks at anything a machine refuses to show.
    ///
    /// **And one file is enough.** The supervisor already watches every `exec` in the reservation,
    /// already marks a process running the repository's own code as tainted, and already inherits
    /// that taint to its children with tainted as the default. So a `.bloom` setup script is
    /// refused whether it runs the wrapper as a child or `exec`s into it, and neither case needs
    /// the process tree to be walked or git's helpers to be recognised.
    static func runAttestor(environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        #if !os(Linux)
        return 1
        #else
        guard getuid() == 0 else { return attestorRefused("not root") }
        guard let peer = identity(prefix: "BLOOM_PERSON_BOUND_PEER", environment: environment),
              let provenance = environment["BLOOM_PERSON_BOUND_PROVENANCE"], provenance.hasPrefix("/")
        else { return attestorRefused("missing identity or provenance directory") }
        // Read again now: a pid that has exited and been reused since the request would otherwise
        // be judged on the record of whoever held it before.
        guard let current = PersonBoundProcIdentity.read(peer.pid), current == peer else {
            return attestorRefused("the caller is no longer the process that asked")
        }
        guard let record = recordFor(peer, directory: provenance) else {
            return attestorRefused("missing protected provenance")
        }
        guard record.status == "trusted" else {
            return attestorRefused("\(record.status) provenance")
        }

        return 0
        #endif
    }

    private static func attestationEnvironment(
        peer: LocalSocket.Peer, binding: PersonBoundProcessRegistry.Binding
    ) -> [String: String] {
        var environment = [
            "PATH": "/usr/bin:/bin",
            "BLOOM_PERSON_BOUND_PROVENANCE": MachineSandbox.personBoundProvenanceRoot + "/"
                + binding.reservation.id.uuidString.lowercased(),
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

    private static func identity(
        prefix: String, environment: [String: String]
    ) -> PersonBoundProcessIdentity? {
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

    static func recordFor(
        _ identity: PersonBoundProcessIdentity, directory: String
    ) -> ProvenanceRecord? {
        let path = directory + "/\(identity.pid)-\(identity.startTime)"

        guard rootOwnsPath(path), let data = try? Data(contentsOf: URL(fileURLWithPath: path))
        else { return nil }

        return try? JSONDecoder().decode(ProvenanceRecord.self, from: data)
    }

    private static func rootOwnsPath(_ path: String) -> Bool {
        PersonBoundTrustedExecutable.rootOwnsPath(path)
    }

    private static func attestorRefused(_ reason: String) -> Int32 {
        FileHandle.standardError.write(Data("bloom-runner: person-bound attestation refused: \(reason)\n".utf8))

        return 1
    }

    /// `liveCommand`, read as the process's own uid and gid rather than as root.
    ///
    /// **A Cloud workspace's machine grants root everything except CAP_SYS_PTRACE**, and
    /// `/proc/<pid>/exe` and `cwd` go through `ptrace_may_access`, which admits a reader on a uid
    /// and gid match or on that capability and nothing else. Both the sandbox supervisor and this
    /// attestor are root and a different uid from what they are looking at, so both read nothing
    /// and refused everything: no workspace started for a day, first as an exec that could not be
    /// identified and then as `process ancestry`.
    ///
    /// The uid and gid come from `/proc/<pid>/status`, which root may read, so nothing has to be
    /// passed in and a process running as root is read as root, unchanged.
    static func liveCommandAsOwner(_ pid: Int32, root: String = "/proc") -> Command? {
        #if !os(Linux)
        return liveCommand(pid, root: root)
        #else
        guard let status = try? String(contentsOfFile: root + "/\(pid)/status", encoding: .utf8),
              let uid = identifier("Uid:", in: status), let gid = identifier("Gid:", in: status)
        else { return nil }

        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { return nil }

        let child = fork()

        guard child >= 0 else {
            close(descriptors[0])
            close(descriptors[1])

            return nil
        }

        if child == 0 {
            close(descriptors[0])
            if setgid(gid) == 0, setuid(uid) == 0,
               let command = liveCommand(pid, root: root),
               let encoded = try? JSONEncoder().encode(command) {
                encoded.withUnsafeBytes { _ = write(descriptors[1], $0.baseAddress, $0.count) }
            }
            close(descriptors[1])
            _exit(0)
        }

        close(descriptors[1])
        var answer = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = read(descriptors[0], &buffer, buffer.count)
            guard count > 0 else { break }
            answer.append(contentsOf: buffer[0..<count])
        }
        close(descriptors[0])
        var status2: Int32 = 0
        _ = waitpid(child, &status2, 0)

        return try? JSONDecoder().decode(Command.self, from: answer)
        #endif
    }

    /// The effective id on a `Uid:` or `Gid:` line, which is its second field.
    private static func identifier(_ label: String, in status: String) -> UInt32? {
        guard let line = status.split(separator: "\n").first(where: { $0.hasPrefix(label) }) else { return nil }

        return line.split(whereSeparator: { $0 == " " || $0 == "\t" }).dropFirst(2).first.flatMap { UInt32($0) }
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

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

}
