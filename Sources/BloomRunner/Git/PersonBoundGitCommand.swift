import BloomCore
import Foundation
#if canImport(Glibc)
import Glibc

@_silgen_name("prctl")
private func linuxPrctl(_ option: Int32, _ second: UInt, _ third: UInt, _ fourth: UInt, _ fifth: UInt) -> Int32
#endif

/// The v2 `git` and `gh` entry points. Classification happens before a credential is requested,
/// and the repository a credential is lent for is fixed by machine configuration.
///
/// **Only what needs the person's GitHub credential is held to a rule here.** This used to refuse
/// every command it did not recognise, so an agent could not run `git config user.name`, could
/// not ask `gh auth status`, and gave up on committing at all. None of those refusals protected
/// anything: the real `git` and `gh` are on the same machine and the agent can run them by path,
/// and neither holds a credential of its own. A command that needs none is run as it is, with no
/// credential; a command that would carry one is confined to this repository or refused.
enum PersonBoundGitCommand {
    struct Invocation: Sendable, Hashable {
        var operation: PersonBoundGithubOperation?
        var arguments: [String]
        /// The refspecs of a `push -u`, taken out of the command because the push cannot write
        /// them: see `upstreams(forPushRefspecs:currentBranch:)`. Nil when there was no `-u`.
        var upstreamRefspecs: [String]?
    }

    /// A branch's upstream, as `branch.<name>.remote=origin` and `branch.<name>.merge`.
    struct GitUpstream: Sendable, Hashable {
        var branch: String
        var merge: String

        init(branch: String, merge: String) {
            self.branch = branch
            self.merge = merge
        }

        /// Nil unless both are plain names, since both end up inside a `-c` argument.
        init?(branch: String, mergeReference: String) {
            guard mergeReference.hasPrefix("refs/heads/"),
                  PersonBoundGitCommand.isPlainBranchName(branch),
                  PersonBoundGitCommand.isPlainBranchName(String(mergeReference.dropFirst("refs/heads/".count)))
            else { return nil }
            self.init(branch: branch, merge: mergeReference)
        }
    }

    /// The commands that reach GitHub and so need a credential. Everything else is local.
    static let networkGitCommands: Set<String> = ["fetch", "pull", "push", "clone", "ls-remote"]

    static func runGit(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) async -> Int32 {
        func refuse(_ reason: String, status: Int32) -> Int32 {
            FileHandle.standardError.write(Data("bloom-runner: git-v2 refused: \(reason)\n".utf8))

            return status
        }
        guard let repository = exactRepository(environment) else {
            return refuse("BLOOM_REPOSITORY names no owner/name repository", status: 64)
        }
        guard let invocation = gitInvocation(arguments, repository: repository) else {
            return refuse(
                "a command that talks to GitHub runs only against origin, which is \(repository), from the "
                    + "current directory, and without -c, -C, --all, --exec-path, --upload-pack, --receive-pack "
                    + "or submodule recursion",
                status: 64
            )
        }
        guard let executable = realTool("git", environment: environment) else {
            return refuse("BLOOM_REAL_GIT names no root-owned git", status: 127)
        }
        // A local command holds nothing worth guarding, so it runs exactly as asked, with the
        // caller's own environment: the PATH its hooks need, and a GIT_EDITOR it chose.
        guard invocation.operation != nil else {
            return await run(executable, invocation.arguments, environment: environment)
        }
        guard let remoteHTTPS = realRemoteHTTPS(environment) else {
            return refuse("BLOOM_REAL_GIT_REMOTE_HTTPS names no root-owned transport", status: 127)
        }
        let upstream = branchUpstreams(for: invocation, git: executable, environment: environment)
        var clean = scrubbed(environment)
        clean["PATH"] = trustedPath(environment)
        let forced = networkArguments(
            for: invocation, repository: repository,
            runnerExecutable: runnerExecutable(environment),
            gitRemoteHTTPSExecutable: remoteHTTPS,
            worktree: environment["BLOOM_WORKTREE"] ?? environment["BLOOM_PERSON_BOUND_WORKTREE"],
            upstream: upstream
        )
        applyCleanConfiguration(to: &clean)
        /*
         * **git-credential-v2 is spawned by git, so it cannot classify anything itself**: all
         * it is ever told is `get`. The wrapper has already classified the command, so it says
         * so here and git passes it down by inheritance, the same way the rest of the clean
         * environment travels. The supervisor used to work this out by reading the process
         * tree instead, which is the thing that refused every Cloud workspace for a day.
         */
        clean[PersonBoundGithubOperation.environmentKey] = invocation.operation?.rawValue
        return await run(executable, forced, environment: clean)
    }

    /// The upstreams a network command should see, read and written while the repository's own
    /// configuration can still be reached.
    ///
    /// **The root supervisor hides `.git/config` for the length of a network command**, by
    /// mounting `/dev/null` over it, so that nothing a checkout wrote there can steer the
    /// transport. That also hides every branch's upstream, and it makes the file unwritable: a
    /// `git push -u` pushed, then printed "could not write config file .git/config: Device or
    /// resource busy" twice and claimed to have set a tracking branch it had not. So the upstream
    /// is written here first, before the mask, and handed to the network command as `-c` along
    /// with the current branch's own, which is what lets a bare `git push` or `git pull` find it.
    /// Only a remote of `origin` is carried, since that is the only remote a credential goes to.
    private static func branchUpstreams(
        for invocation: Invocation, git: String, environment: [String: String]
    ) -> [GitUpstream] {
        let current = plainGit(git, ["symbolic-ref", "--quiet", "--short", "HEAD"], environment: environment)
        var found: [GitUpstream] = []
        let requested = invocation.upstreamRefspecs.map { upstreams(forPushRefspecs: $0, currentBranch: current) } ?? []
        for upstream in requested {
            let branch = upstream.branch
            guard plainGit(git, ["rev-parse", "--verify", "--quiet", "refs/heads/" + branch], environment: environment) != nil,
                  plainGit(git, ["config", "branch.\(branch).remote", "origin"], environment: environment) != nil,
                  plainGit(git, ["config", "branch.\(branch).merge", upstream.merge], environment: environment) != nil
            else { continue }
            found.append(upstream)
            let merged = upstream.merge.dropFirst("refs/heads/".count)
            FileHandle.standardError.write(Data("branch '\(branch)' set up to track 'origin/\(merged)'.\n".utf8))
        }
        if let current, !found.contains(where: { $0.branch == current }),
           plainGit(git, ["config", "--get", "branch.\(current).remote"], environment: environment) == "origin",
           let merge = plainGit(git, ["config", "--get", "branch.\(current).merge"], environment: environment),
           let upstream = GitUpstream(branch: current, mergeReference: merge) {
            found.append(upstream)
        }
        return found
    }

    /// What `git push -u` would record, for each refspec it was given.
    ///
    /// Only plain branch names come through, since both halves go into `-c` arguments: a name
    /// with `=` in it would split there. A refspec pushing to anything but a branch is left alone,
    /// as git itself does.
    static func upstreams(forPushRefspecs refspecs: [String], currentBranch: String?) -> [GitUpstream] {
        (refspecs.isEmpty ? ["HEAD"] : refspecs).compactMap { refspec in
            let text = refspec.hasPrefix("+") ? String(refspec.dropFirst()) : refspec
            let halves = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            var source = halves[0]
            var destination = halves.count == 2 ? halves[1] : halves[0]
            if source == "HEAD" {
                guard let currentBranch else { return nil }
                source = currentBranch
            }
            if destination == "HEAD" { destination = source }
            if source.hasPrefix("refs/heads/") { source.removeFirst("refs/heads/".count) }
            if destination.hasPrefix("refs/heads/") {
                destination.removeFirst("refs/heads/".count)
            } else if destination.hasPrefix("refs/") {
                return nil
            }
            guard isPlainBranchName(source), isPlainBranchName(destination) else { return nil }
            return GitUpstream(branch: source, merge: "refs/heads/" + destination)
        }
    }

    static func isPlainBranchName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-") && !name.hasPrefix("/") && !name.hasSuffix("/")
            && !name.contains("..") && !name.hasSuffix(".lock")
            && name.unicodeScalars.allSatisfy { scalar in
                CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII
                    || scalar == "." || scalar == "_" || scalar == "-" || scalar == "/"
            }
    }

    /// Runs the real git with no credential and answers its trimmed output, or nil if it failed.
    private static func plainGit(_ git: String, _ arguments: [String], environment: [String: String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    static func runGh(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) async -> Int32 {
        guard let repository = exactRepository(environment) else {
            return ghRefused("BLOOM_REPOSITORY names no owner/name repository", status: 64)
        }
        let invocation: Invocation
        switch ghClassification(arguments, repository: repository) {
        case let .refused(reason):
            return ghRefused(reason, status: 64)
        case let .plain(plain):
            invocation = Invocation(operation: nil, arguments: plain)
        case let .credential(operation, forced):
            invocation = Invocation(operation: operation, arguments: forced)
        }
        guard let executable = realTool("gh", environment: environment) else {
            return ghRefused("root-owned executable", status: 127)
        }
        var clean = scrubbed(environment)
        clean["PATH"] = trustedPath(environment)
        applyCleanConfiguration(to: &clean)
        // gh runs git itself, to find the branch and its remote, and that git reads no system
        // configuration here, so it would refuse a worktree another uid created as "dubious
        // ownership". The worktree comes from machine configuration, never from the caller.
        if let worktree = environment["BLOOM_WORKTREE"] ?? environment["BLOOM_PERSON_BOUND_WORKTREE"],
           worktree.hasPrefix("/") {
            clean["GIT_CONFIG_COUNT"] = "1"
            clean["GIT_CONFIG_KEY_0"] = "safe.directory"
            clean["GIT_CONFIG_VALUE_0"] = worktree
        }
        guard invocation.operation != nil else {
            // Said, because what follows is otherwise gh's own "not logged in", which reads like a
            // machine with no GitHub at all rather than a command that was lent nothing.
            if let first = arguments.first, !["version", "--version", "help", "--help"].contains(first) {
                FileHandle.standardError.write(Data((
                    "bloom-runner: gh-v2 runs this without a GitHub credential, as it is not a command "
                        + "Bloom knows to stay inside \(repository)\n"
                ).utf8))
            }
            return await run(executable, invocation.arguments, environment: clean)
        }
        #if os(Linux)
        guard rootOwnedFilePath(MachineSandbox.personBoundCredentialShield) else {
            return ghRefused("credential shield", status: 1)
        }
        clean["LD_PRELOAD"] = MachineSandbox.personBoundCredentialShield
        #endif
        let foundationSelfTest = environment["BLOOM_PERSON_BOUND_FOUNDATION_SELF_TEST"] == "1"
        guard let classified = invocation.operation else {
            return ghRefused("command classification", status: 64)
        }
        let request = PersonBoundCredentialRequest(repository: repository, operation: classified)
        guard let answer = LocalCredentialClient.askV2(
            request, over: MachineSandbox.credentialV2SocketPath
        ) else { return ghRefused("credential exchange", status: 1) }
        guard makeCredentialProcessPrivate() else { return ghRefused("process privacy", status: 1) }
        clean["GH_TOKEN"] = answer.token
        clean["GH_HOST"] = "github.com"
        clean["GH_REPO"] = "github.com/\(repository)"
        if foundationSelfTest {
            return runFoundationSelfTest(answer: answer, repository: repository)
        }
        return await run(executable, invocation.arguments, environment: clean)
    }

    /// **Every refusal here says which one it was.** git reports all of them as the same sentence,
    /// "unable to get password from user", and a machine that printed nothing beside it cost a day
    /// of looking in the wrong place.
    static func runCredentialHelper(
        _ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int32 {
        func refuse(_ reason: String) -> Int32 {
            FileHandle.standardError.write(Data("bloom-runner: git-credential-v2 refused: \(reason)\n".utf8))

            return 1
        }
        // **git calls `store` after a successful authentication and `erase` after a failed one.**
        // Neither has anything to do with this helper, which holds no store to write to, so both
        // are answered with silence and success. Refusing them changed nothing for git and put a
        // line that reads like a fault into the one log a person looks at after a clone.
        if arguments.first == "store" || arguments.first == "erase" { return 0 }
        guard arguments.first == "get", arguments.count == 1 else {
            return refuse("asked for something other than a single `get`")
        }
        guard let repository = exactRepository(environment) else {
            return refuse("BLOOM_REPOSITORY names no owner/name repository")
        }
        let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        let fields = credentialFields(input)
        guard fields["protocol"]?.lowercased() == "https",
              fields["host"]?.lowercased() == "github.com",
              let path = fields["path"],
              credentialRepository(fromPath: path)?.lowercased() == repository.lowercased() else {
            return refuse("git asked about \(fields["host"] ?? "nothing")/\(fields["path"] ?? ""), not \(repository)")
        }
        guard let declared = environment[PersonBoundGithubOperation.environmentKey]
            .flatMap(PersonBoundGithubOperation.init(rawValue:)) else {
            return refuse("\(PersonBoundGithubOperation.environmentKey) was not set by the git wrapper")
        }
        guard let answer = LocalCredentialClient.askV2(
            PersonBoundCredentialRequest(repository: repository, operation: declared),
            over: MachineSandbox.credentialV2SocketPath
        ) else { return refuse("the credential exchange was refused") }
        guard makeCredentialProcessPrivate() else { return 1 }
        print("username=\(answer.username)")
        print("password=\(answer.token)")
        return 0
    }

    private static func runFoundationSelfTest(
        answer: PersonBoundCredentialAnswer, repository: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int32 {
        #if !os(Linux)
        return 1
        #else
        var socket = stat()
        guard lstat("/.sprite/api.sock", &socket) == 0,
              socket.st_mode & mode_t(S_IFMT) != mode_t(S_IFSOCK),
              answer.username == "x-access-token", answer.token == "bloom-person-bound-self-test" else { return 1 }
        // Asked again, with the same operation, from the same process. That is what a replay is,
        // and the broker must refuse it on the operation identity it has already spent, without
        // going near the network. Asking with a different operation would be a different question
        // and would prove nothing about replay.
        let request = PersonBoundCredentialRequest(repository: repository, operation: .ghRead)
        guard LocalCredentialClient.askV2(
                  request, over: MachineSandbox.credentialV2SocketPath
              ) == nil else { return 1 }
        return 0
        #endif
    }

    /// Nil is a refusal, and only a command that talks to GitHub is ever refused: anything else
    /// comes back with no operation and runs as plain git, with no credential.
    static func gitInvocation(_ arguments: [String], repository: String) -> Invocation? {
        guard let commandIndex = gitCommandIndex(arguments),
              networkGitCommands.contains(arguments[commandIndex]) else {
            return Invocation(operation: nil, arguments: arguments)
        }
        let command = arguments[commandIndex]
        let leading = Array(arguments[..<commandIndex])
        guard leadingConfigurationIsSafe(leading) else { return nil }
        let canonical = "https://github.com/\(repository).git"
        let tail = Array(arguments[(commandIndex + 1)...])
        switch command {
        case "fetch", "pull", "push":
            let operation: PersonBoundGithubOperation = command == "push" ? .gitWrite : .gitRead
            guard let forced = forcedRemoteTail(tail, repository: repository, isPush: command == "push") else { return nil }
            return Invocation(
                operation: operation, arguments: leading + [command] + forced.arguments,
                upstreamRefspecs: forced.setsUpstream ? forced.refspecs : nil
            )
        default:
            guard !tail.contains(where: forbiddenNetworkArgument) else { return nil }
            // `git ls-remote` and `git ls-remote origin` mean this repository too. It is given the
            // URL, never `origin`, for the reason on `networkArguments`.
            if command == "ls-remote", firstPositional(in: tail) == nil {
                return Invocation(operation: .gitRead, arguments: leading + [command] + tail + [canonical])
            }
            guard let source = firstPositional(in: tail),
                  exactURL(source, repository: repository) || command == "ls-remote" && source == "origin" else { return nil }
            return Invocation(operation: .gitRead, arguments: leading + [command] + replacingFirst(source, in: tail, with: canonical))
        }
    }

    /// What gh-v2 does with a command: lends it a credential for one operation, runs it with none,
    /// or refuses it and says why.
    enum GhClassification: Sendable, Hashable {
        case credential(PersonBoundGithubOperation, [String])
        case plain([String])
        case refused(String)
    }

    /// The commands gh-v2 lends a credential to, confined to this repository with `--repo`.
    private static let ghRepositoryActions: [String: (read: Set<String>, write: Set<String>)] = [
        "pr": (["list", "status", "view", "checks", "diff"],
               ["create", "comment", "review", "merge", "close", "reopen", "ready", "edit", "update-branch"]),
        "issue": (["list", "status", "view"], ["create", "comment", "close", "reopen", "edit", "delete"]),
        "run": (["list", "view", "watch", "download"], ["rerun", "cancel", "delete"]),
        "workflow": (["list", "view"], ["run", "enable", "disable"]),
        "release": (["list", "view", "download"], ["edit", "delete"]),
        "label": (["list"], ["create", "edit"]),
        "cache": (["list"], ["delete"]),
    ]

    static func ghInvocation(_ arguments: [String], repository: String) -> Invocation? {
        switch ghClassification(arguments, repository: repository) {
        case let .credential(operation, forced): Invocation(operation: operation, arguments: forced)
        case let .plain(plain): Invocation(operation: nil, arguments: plain)
        case .refused: nil
        }
    }

    /// **A command gh-v2 does not know runs with no credential rather than being refused.** gh has
    /// no token of its own on a machine, since its configuration directory is an empty one that
    /// root owns, so a command that was lent nothing can do nothing with anybody's GitHub. What is
    /// refused is what would take the lent token further than this one repository, or show it:
    /// `auth token` and `auth status --show-token` print it; `auth login`, `logout`, `refresh`,
    /// `setup-git` and `switch` exist to store or replace one; `--hostname` points it at another
    /// host; `--repo` naming another repository, or a GitHub URL for one, aims it elsewhere; and a
    /// flag that makes gh read a file (`--body-file`, `-F`, `--notes-file`, `api --input`, a
    /// `-F key=@file` field) could read `/proc/self/environ`, which is where the token is, and
    /// post it. `gh api` is lent a credential only for this repository's own `repos/` paths.
    static func ghClassification(_ arguments: [String], repository: String) -> GhClassification {
        guard let command = arguments.first else { return .plain(arguments) }
        if arguments.contains(where: { $0 == "--hostname" || $0.hasPrefix("--hostname=") }) {
            return .refused("--hostname would take this repository's credential to another host")
        }
        switch command {
        case "auth": return ghAuth(arguments)
        case "api": return ghAPI(arguments, repository: repository)
        case "repo": return ghRepoView(arguments, repository: repository)
        default: break
        }
        guard let allowed = ghRepositoryActions[command], arguments.indices.contains(1),
              allowed.read.contains(arguments[1]) || allowed.write.contains(arguments[1]) else {
            return .plain(arguments)
        }
        let operation: PersonBoundGithubOperation = allowed.write.contains(arguments[1]) ? .ghWrite : .ghRead
        if let flag = arguments.first(where: { value in
            ["--web", "--editor", "--browser", "--body-file", "-F", "--notes-file", "--recover"].contains(value)
                || value.hasPrefix("--body-file=") || value.hasPrefix("--notes-file=")
                || value.hasPrefix("--recover=") || value.hasPrefix("-F")
        }) {
            return .refused(
                "\(flag) opens a browser or an editor, or makes gh read a file while it holds the token; "
                    + "pass the text itself, with --body or --notes"
            )
        }
        if let other = arguments.first(where: { githubURL($0, namesAnotherRepositoryThan: repository) }) {
            return .refused("\(other) is another repository, and the credential here is for \(repository) only")
        }
        guard !arguments.contains(where: { $0.hasPrefix("--repo=") || $0.hasPrefix("-R=") }) else {
            return .refused("give the repository as --repo \(repository), or leave it out")
        }
        var forced = arguments
        let repositoryFlags = forced.indices.filter { forced[$0] == "--repo" || forced[$0] == "-R" }
        guard repositoryFlags.count <= 1 else { return .refused("--repo was given more than once") }
        if let index = repositoryFlags.first {
            guard forced.indices.contains(index + 1), forced[index + 1].lowercased() == repository.lowercased() else {
                return .refused("the credential here is for \(repository) only")
            }
        } else {
            forced += ["--repo", repository]
        }
        return .credential(operation, forced)
    }

    private static func ghAuth(_ arguments: [String]) -> GhClassification {
        let action = arguments.dropFirst().first
        guard action == "status" else {
            if action == "token" { return .refused("gh auth token would print the credential") }
            if let action, ["login", "logout", "refresh", "setup-git", "switch"].contains(action) {
                return .refused("gh auth \(action) would store or replace a credential; Bloom lends one per command")
            }
            return .plain(arguments)
        }
        guard !arguments.contains(where: { $0 == "-t" || $0 == "--show-token" || $0.hasPrefix("--show-token=") }) else {
            return .refused("--show-token would print the credential")
        }
        return .credential(.ghRead, arguments)
    }

    private static func ghRepoView(_ arguments: [String], repository: String) -> GhClassification {
        guard arguments.dropFirst().first == "view" else { return .plain(arguments) }
        if let flag = arguments.first(where: { $0 == "--web" || $0 == "-w" }) {
            return .refused("\(flag) opens a browser")
        }
        let takesValue: Set<String> = ["-b", "--branch", "--json", "-q", "--jq", "-t", "--template"]
        var positional: [String] = []
        var index = 2
        while index < arguments.count {
            let value = arguments[index]
            if takesValue.contains(value) {
                index += 2
                continue
            }
            if !value.hasPrefix("-") { positional.append(value) }
            index += 1
        }
        // `gh repo view` takes the repository as its argument and has no --repo flag.
        guard positional.isEmpty else {
            guard positional.map({ $0.lowercased() }) == [repository.lowercased()] else {
                return .refused("the credential here is for \(repository) only")
            }
            return .credential(.ghRead, arguments)
        }
        return .credential(.ghRead, Array(arguments.prefix(2)) + [repository] + Array(arguments.dropFirst(2)))
    }

    /// `gh api`, confined to `repos/<this repository>`. A GET is a read and anything else a write,
    /// which is how gh itself decides: a field without `--method` makes it a POST.
    private static func ghAPI(_ arguments: [String], repository: String) -> GhClassification {
        let takesValue: Set<String> = [
            "-X", "--method", "-H", "--header", "-f", "--raw-field", "-F", "--field", "-q", "--jq",
            "-t", "--template", "--cache", "-p", "--preview", "--input",
        ]
        var endpoint: String?
        var method: String?
        var hasFields = false
        var index = 1
        while index < arguments.count {
            let value = arguments[index]
            let (flag, inline) = value.hasPrefix("--") && value.contains("=")
                ? (String(value.prefix { $0 != "=" }), String(value.drop { $0 != "=" }.dropFirst()))
                : (value, nil)
            if flag == "--input" { return .refused("--input makes gh read a file while it holds the token") }
            if flag == "--verbose" { return .refused("--verbose prints the request, headers and all") }
            if takesValue.contains(flag) {
                guard let argument = inline ?? (arguments.indices.contains(index + 1) ? arguments[index + 1] : nil) else {
                    return .refused("\(flag) is missing its value")
                }
                if flag == "-X" || flag == "--method" { method = argument.uppercased() }
                if ["-f", "--raw-field", "-F", "--field"].contains(flag) { hasFields = true }
                if flag == "-F" || flag == "--field", argument.contains("=@") {
                    return .refused("a -F field of @file makes gh read a file while it holds the token")
                }
                index += inline == nil ? 2 : 1
                continue
            }
            if !value.hasPrefix("-"), endpoint == nil { endpoint = value }
            index += 1
        }
        guard let endpoint else { return .plain(arguments) }
        let path = endpoint.drop { $0 == "/" }.lowercased()
        let roots = ["repos/" + repository.lowercased(), "repos/{owner}/{repo}"]
        guard !path.contains(".."), !path.contains("%2e"), !path.contains("://"),
              roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") || path.hasPrefix($0 + "?") })
        else {
            return .refused("gh api is lent a credential only for repos/\(repository)/..., and \(endpoint) is not one")
        }
        let effective = method ?? (hasFields ? "POST" : "GET")
        return .credential(effective == "GET" ? .ghRead : .ghWrite, arguments)
    }

    /// Whether an argument is a GitHub URL for some other repository. Only one that starts with
    /// the URL counts, because that is what a positional argument naming a pull request looks
    /// like; a body or a title that mentions another repository somewhere inside it is text.
    private static func githubURL(_ value: String, namesAnotherRepositoryThan repository: String) -> Bool {
        let lower = value.lowercased()
        let prefixes = ["https://github.com/", "http://github.com/", "github.com/", "https://www.github.com/"]
        guard let prefix = prefixes.first(where: lower.hasPrefix) else { return false }
        let path = lower.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: true)
        guard path.count >= 2 else { return true }
        var name = String(path[1])
        if name.hasSuffix(".git") { name.removeLast(4) }
        return "\(path[0])/\(name)" != repository.lowercased()
    }

    static func credentialFields(_ input: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in input.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
        }
        return fields
    }

    static func credentialRepository(fromPath path: String) -> String? {
        var trimmed = path
        if trimmed.hasSuffix(".git") { trimmed.removeLast(4) }
        let parts = trimmed.split(separator: "/")
        guard parts.count == 2 else { return nil }
        return parts.joined(separator: "/")
    }

    private static func gitCommandIndex(_ arguments: [String]) -> Int? {
        var index = 0
        while index < arguments.count {
            let value = arguments[index]
            if value == "-c" || value == "--config-env" || value == "-C" || value == "--git-dir" || value == "--work-tree" {
                index += 2
                continue
            }
            if value.hasPrefix("-") { index += 1; continue }
            return index
        }
        return nil
    }

    private static func leadingConfigurationIsSafe(_ arguments: [String]) -> Bool {
        let harmless = Set([
            "--no-pager", "--paginate", "-p", "--literal-pathspecs", "--no-literal-pathspecs",
            "--glob-pathspecs", "--noglob-pathspecs", "--icase-pathspecs", "--no-replace-objects",
            "--no-optional-locks",
        ])
        return arguments.allSatisfy(harmless.contains)
    }

    /// The tail of a fetch, pull or push, always naming `origin`, which `networkArguments` points
    /// at the one repository. `-u` is taken out of a push and reported instead, for the reason on
    /// `branchUpstreams`.
    ///
    /// **`origin` by name, not the URL in its place.** This used to swap the URL in, and git
    /// updates remote-tracking refs only for a named remote, so after a push there was no
    /// `origin/<branch>`: `gh pr create` looks for exactly that to know the branch was pushed, and
    /// answered "you must first push the current branch". A `git fetch origin` left `origin/main`
    /// where it was, too, so a rebase onto it rebased onto yesterday.
    private static func forcedRemoteTail(
        _ arguments: [String], repository: String, isPush: Bool
    ) -> (arguments: [String], refspecs: [String], setsUpstream: Bool)? {
        var output: [String] = []
        var refspecs: [String] = []
        var sawRemote = false
        var setsUpstream = false
        var index = 0
        let takesValue: Set<String> = [
            "--depth", "--deepen", "--shallow-since", "--shallow-exclude", "--jobs", "-j",
            "--server-option", "--negotiation-tip", "--filter", "-o", "--push-option",
        ]
        while index < arguments.count {
            let value = arguments[index]
            guard !forbiddenNetworkArgument(value) else { return nil }
            if takesValue.contains(value) {
                guard arguments.indices.contains(index + 1) else { return nil }
                output += [value, arguments[index + 1]]
                index += 2
                continue
            }
            if isPush, value == "-u" || value == "--set-upstream" {
                setsUpstream = true
                index += 1
                continue
            }
            if value.hasPrefix("-") {
                let forbidden = ["--all", "--multiple", "--stdin", "--upload-pack", "--receive-pack", "--exec", "--recurse-submodules"]
                guard !looksLikeExternalTransport(value), !forbidden.contains(where: value.hasPrefix) else { return nil }
                output.append(value)
                index += 1
                continue
            }
            if !sawRemote {
                guard value == "origin" || exactURL(value, repository: repository) else { return nil }
                sawRemote = true
                output.append("origin")
            } else {
                guard !looksLikeExternalTransport(value) else { return nil }
                output.append(value)
                refspecs.append(value)
            }
            index += 1
        }
        if !sawRemote { output.append("origin") }
        return (output, refspecs, setsUpstream)
    }

    private static func firstPositional(in arguments: [String]) -> String? {
        let takesValue: Set<String> = [
            "-b", "--branch", "-o", "--origin", "--depth", "--shallow-since", "--shallow-exclude",
            "--reference", "--reference-if-able", "--separate-git-dir", "--jobs", "-j", "--filter",
            "--server-option",
        ]
        var index = 0
        while index < arguments.count {
            let value = arguments[index]
            if takesValue.contains(value) {
                guard arguments.indices.contains(index + 1) else { return nil }
                index += 2
            } else if value.hasPrefix("-") {
                index += 1
            } else {
                return value
            }
        }
        return nil
    }

    private static func replacingFirst(_ value: String, in arguments: [String], with replacement: String) -> [String] {
        var copy = arguments
        if let index = copy.firstIndex(of: value) { copy[index] = replacement }
        return copy
    }

    private static func exactURL(_ value: String, repository: String) -> Bool {
        let lower = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let repo = repository.lowercased()
        return lower == "https://github.com/\(repo)" || lower == "https://github.com/\(repo).git"
    }

    private static func looksLikeExternalTransport(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("://") || lower.hasPrefix("git@") || lower.hasPrefix("ssh:")
            || lower.contains("ext::") || lower.contains("github.com:")
    }

    private static func forbiddenNetworkArgument(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower == "-c" || lower.hasPrefix("--config") || lower.hasPrefix("--exec-path")
            || lower.hasPrefix("--upload-pack") || lower.hasPrefix("--receive-pack")
            || lower.hasPrefix("--exec") || lower.hasPrefix("--hooks-path")
            || lower.hasPrefix("--recurse-submodules") || lower.hasPrefix("--remote-submodules")
            || lower.hasPrefix("--template")
    }

    private static func exactRepository(_ environment: [String: String]) -> String? {
        guard let repository = environment["BLOOM_REPOSITORY"], repository.split(separator: "/").count == 2,
              repository.utf8.allSatisfy({ byte in
                  (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                      || byte == 45 || byte == 46 || byte == 95 || byte == 47
              })
        else { return nil }
        return repository
    }

    static func scrubbed(_ environment: [String: String]) -> [String: String] {
        var clean = environment
        for key in clean.keys where key.hasPrefix("GH_") || key.hasPrefix("GITHUB_") || key.hasPrefix("GIT_ASKPASS")
            || key.hasPrefix("GIT_SSH") || key.hasPrefix("GIT_CONFIG_") || key == "SSH_ASKPASS"
            || key == "GIT_EXEC_PATH" || key == "GIT_PROXY_COMMAND" || key == "GIT_EXTERNAL_DIFF"
            || key == "BASH_ENV" || key == "ENV" || key == "CDPATH" || key.hasPrefix("LD_")
            || key.hasPrefix("DYLD_") || key.hasPrefix("GIT_TRACE") || key.hasPrefix("GIT_SSL")
            || key.hasPrefix("GIT_HTTP") || key.hasPrefix("CURL_") || key.hasPrefix("SSL_CERT")
            || key == "GIT_ALLOW_PROTOCOL" || key == "GIT_PROTOCOL_FROM_USER"
            || key == "GIT_CONFIG_NOSYSTEM" || key == "GIT_CONFIG_SYSTEM" || key == "GIT_CONFIG_GLOBAL"
            || key == "GIT_CURL_VERBOSE" || key == "GIT_REDIRECT_STDERR" || key == "GH_DEBUG"
            || key.uppercased() == "HTTP_PROXY" || key.uppercased() == "HTTPS_PROXY"
            || key.uppercased() == "ALL_PROXY" || key.uppercased() == "NO_PROXY" {
            clean.removeValue(forKey: key)
        }
        clean["GIT_TERMINAL_PROMPT"] = "0"
        clean["GIT_ASKPASS"] = "/bin/false"
        clean["GH_PROMPT_DISABLED"] = "1"
        clean["GH_PAGER"] = "cat"
        clean["PAGER"] = "cat"
        clean["GH_EDITOR"] = "false"
        clean["GIT_EDITOR"] = "false"
        clean["EDITOR"] = "false"
        return clean
    }

    static func networkArguments(
        for invocation: Invocation,
        repository: String,
        runnerExecutable: String,
        gitRemoteHTTPSExecutable: String,
        worktree: String? = nil,
        upstream: [GitUpstream] = []
    ) -> [String] {
        let helper = "!\(MachineGitTools.shellQuoted(runnerExecutable)) git-credential-v2"
        let execPath = URL(fileURLWithPath: gitRemoteHTTPSExecutable).deletingLastPathComponent().path
        let canonical = "https://github.com/\(repository).git"
        /*
         * **No empty `sslCert`.** Setting it to nothing reads like "use no client certificate" and
         * is not: curl takes the empty string as a filename, tries to open it, and every clone dies
         * with "error reading X.509 key file: Error while reading file". Measured one setting at a
         * time: empty `sslCAPath` and empty `sslKey` are both harmless, and empty `sslCert` alone
         * breaks it. So it is left alone, and what actually stops a client certificate being
         * inherited is the clean configuration directory this runs with, which is root owned and
         * holds nothing for anybody to set it in.
         */
        let certificate = "/etc/ssl/certs/ca-certificates.crt"
        let endpoints = [canonical, canonical + "/info/refs", canonical + "/git-upload-pack",
                         canonical + "/git-receive-pack"]
        let fixedHTTP = endpoints.flatMap { endpoint in
            [
                "-c", "http.\(endpoint).proxy=",
                "-c", "http.\(endpoint).sslVerify=true",
                "-c", "http.\(endpoint).sslCAInfo=\(certificate)",
                "-c", "http.\(endpoint).sslCAPath=",
                "-c", "http.\(endpoint).extraHeader=",
                "-c", "http.\(endpoint).curloptResolve=",
                "-c", "http.\(endpoint).cookieFile=",
                "-c", "http.\(endpoint).saveCookies=false",
                "-c", "http.\(endpoint).followRedirects=false",
            ]
        }
        /*
         * **A network operation cannot read the system-wide `safe.directory`, so it has to be
         * given one.** These run with `GIT_CONFIG_NOSYSTEM=1` and `GIT_CONFIG_SYSTEM=/dev/null`,
         * deliberately, so that nothing a caller has written into a config file can reach the
         * transport. What that also discards is the `safe.directory` entry provision-sandbox.sh
         * writes for the worktree, and a worktree is cloned under one person's uid and pushed
         * under another's, so every fetch and push by anyone who did not perform the clone died
         * with "detected dubious ownership" while `git commit` beside it worked, because a local
         * command still reads the system config. The value is the worktree from machine
         * configuration, never anything a caller passes.
         */
        let safeDirectory = worktree.map { ["-c", "safe.directory=\($0)"] } ?? []
        /*
         * `origin` is defined here, because the repository's own definition of it is hidden with
         * the rest of `.git/config` for the length of the command. See `forcedRemoteTail`.
         *
         * **Only for a fetch, pull or push, which run inside a repository.** A clone defines its
         * own origin, and one defined twice failed every clone with "multiple updates for ref
         * refs/remotes/origin/...". And with no repository at all, git 2.53's git-remote-https
         * died of signal 11 reading a command-line `remote.origin.fetch`, which made every
         * `git ls-remote <url>` outside a checkout a segfault. Both measured on a Cloud machine.
         */
        let command = gitCommandIndex(invocation.arguments).map { invocation.arguments[$0] }
        let namesOrigin = command.map { ["fetch", "pull", "push"].contains($0) } ?? false
        let origin = namesOrigin ? [
            "-c", "remote.origin.url=\(canonical)",
            "-c", "remote.origin.fetch=+refs/heads/*:refs/remotes/origin/*",
            "-c", "remote.origin.proxy=",
        ] + upstream.flatMap { upstream in
            ["-c", "branch.\(upstream.branch).remote=origin", "-c", "branch.\(upstream.branch).merge=\(upstream.merge)"]
        } : []
        return safeDirectory + origin + [
            "--exec-path=\(execPath)",
            "-c", "credential.helper=",
            "-c", "credential.helper=\(helper)",
            "-c", "credential.useHttpPath=true",
            "-c", "credential.interactive=false",
            "-c", "core.hooksPath=/dev/null",
            "-c", "core.fsmonitor=false",
            "-c", "core.sshCommand=/bin/false",
            "-c", "protocol.allow=never",
            "-c", "protocol.https.allow=always",
            "-c", "submodule.recurse=false",
            "-c", "http.proxy=",
            "-c", "http.sslVerify=true",
            "-c", "http.sslCAInfo=\(certificate)",
            "-c", "http.sslCAPath=",
            "-c", "http.extraHeader=",
            "-c", "http.curloptResolve=",
            "-c", "http.cookieFile=",
            "-c", "http.saveCookies=false",
            "-c", "http.followRedirects=false",
            "-c", "http.\(canonical).proxy=",
            "-c", "http.\(canonical).sslVerify=true",
            "-c", "http.\(canonical).sslCAInfo=\(certificate)",
            "-c", "http.\(canonical).sslCAPath=",
            "-c", "http.\(canonical).extraHeader=",
            "-c", "http.\(canonical).curloptResolve=",
            "-c", "http.\(canonical).followRedirects=false",
            "-c", "remote.\(canonical).proxy=",
        ] + fixedHTTP + invocation.arguments
    }

    static func networkEnvironmentIsClean(
        _ environment: [String: String], cleanConfigDirectory: String
    ) -> Bool {
        let required = [
            "HOME": cleanConfigDirectory,
            "XDG_CONFIG_HOME": cleanConfigDirectory,
            "GH_CONFIG_DIR": cleanConfigDirectory,
            "GIT_ALLOW_PROTOCOL": "https",
            "GIT_PROTOCOL_FROM_USER": "0",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_COUNT": "0",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_ASKPASS": "/bin/false",
            "GIT_SSL_NO_VERIFY": "0",
            "GIT_SSL_CAINFO": "/etc/ssl/certs/ca-certificates.crt",
            "SSL_CERT_FILE": "/etc/ssl/certs/ca-certificates.crt",
            "HTTP_PROXY": "",
            "HTTPS_PROXY": "",
            "ALL_PROXY": "",
            "NO_PROXY": "github.com",
        ]
        guard required.allSatisfy({ environment[$0.key] == $0.value }) else { return false }
        return !environment.keys.contains(where: unsafeTransportEnvironmentKey)
    }

    static func applyCleanConfiguration(to environment: inout [String: String]) {
        environment["HOME"] = MachineSandbox.personBoundCleanConfigDirectory
        environment["XDG_CONFIG_HOME"] = MachineSandbox.personBoundCleanConfigDirectory
        environment["GH_CONFIG_DIR"] = MachineSandbox.personBoundCleanConfigDirectory
        environment["GIT_ALLOW_PROTOCOL"] = "https"
        environment["GIT_PROTOCOL_FROM_USER"] = "0"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_COUNT"] = "0"
        environment["GIT_SSL_NO_VERIFY"] = "0"
        environment["GIT_SSL_CAINFO"] = "/etc/ssl/certs/ca-certificates.crt"
        environment["SSL_CERT_FILE"] = "/etc/ssl/certs/ca-certificates.crt"
        environment["HTTP_PROXY"] = ""
        environment["HTTPS_PROXY"] = ""
        environment["ALL_PROXY"] = ""
        environment["NO_PROXY"] = "github.com"
    }

    private static func unsafeTransportEnvironmentKey(_ key: String) -> Bool {
        let upper = key.uppercased()
        if ["HOME", "XDG_CONFIG_HOME", "GH_CONFIG_DIR", "GH_PROMPT_DISABLED", "GH_PAGER", "GH_EDITOR",
            "GIT_ALLOW_PROTOCOL", "GIT_PROTOCOL_FROM_USER",
            "GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_COUNT",
            "GIT_TERMINAL_PROMPT", "GIT_ASKPASS", "GIT_SSL_NO_VERIFY", "GIT_SSL_CAINFO",
            "SSL_CERT_FILE", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"].contains(upper) {
            return false
        }
        return upper.hasPrefix("GH_") || upper.hasPrefix("GITHUB_")
            || upper.hasPrefix("GIT_CONFIG_") || upper.hasPrefix("GIT_SSH")
            || upper.hasPrefix("GIT_ASKPASS") || upper.hasPrefix("GIT_TRACE")
            || upper.hasPrefix("GIT_SSL") || upper.hasPrefix("GIT_HTTP")
            || upper.hasPrefix("CURL_") || upper.hasPrefix("SSL_CERT")
            || upper == "HTTP_PROXY" || upper == "HTTPS_PROXY" || upper == "ALL_PROXY"
            || upper == "NO_PROXY" || upper.hasPrefix("LD_") || upper.hasPrefix("DYLD_")
    }

    private static func runnerExecutable(_ environment: [String: String]) -> String {
        environment["BLOOM_RUNNER_EXECUTABLE"] ?? CommandLine.arguments.first ?? "bloom-runner"
    }

    private static func realTool(_ name: String, environment: [String: String]) -> String? {
        let key = name == "git" ? "BLOOM_REAL_GIT" : "BLOOM_REAL_GH"
        guard let candidate = environment[key], candidate.hasPrefix("/"),
              URL(fileURLWithPath: candidate).lastPathComponent == name,
              FileManager.default.isExecutableFile(atPath: candidate) else { return nil }
        let resolved = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
        #if os(Linux)
        guard rootOwnedExecutablePath(resolved) else { return nil }
        #endif
        return resolved
    }

    private static func realRemoteHTTPS(_ environment: [String: String]) -> String? {
        guard let candidate = environment["BLOOM_REAL_GIT_REMOTE_HTTPS"], candidate.hasPrefix("/"),
              URL(fileURLWithPath: candidate).lastPathComponent == "git-remote-https",
              FileManager.default.isExecutableFile(atPath: candidate) else { return nil }
        let resolved = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
        #if os(Linux)
        guard rootOwnedExecutablePath(resolved) else { return nil }
        #endif
        return resolved
    }

    static func gitRemoteHTTPSExecutable(gitExecutable: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitExecutable)
        process.arguments = ["--exec-path"]
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let directory = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let remote = URL(fileURLWithPath: directory).appendingPathComponent("git-remote-https").path
            guard FileManager.default.isExecutableFile(atPath: remote) else { return nil }
            #if os(Linux)
            guard rootOwnedExecutablePath(URL(fileURLWithPath: remote).resolvingSymlinksInPath().path) else { return nil }
            #endif
            return remote
        } catch {
            return nil
        }
    }

    #if os(Linux)
    private static func rootOwnedFilePath(_ path: String) -> Bool {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue else { return false }
        return rootOwnsPath(path)
    }

    private static func rootOwnedExecutablePath(_ path: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        return rootOwnsPath(path)
    }

    private static func rootOwnsPath(_ path: String) -> Bool {
        var current = path
        while current != "/" {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: current),
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == 0,
                  let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value,
                  mode & 0o022 == 0 else { return false }
            current = URL(fileURLWithPath: current).deletingLastPathComponent().path
        }
        return true
    }
    #endif

    private static func trustedPath(_ environment: [String: String]) -> String {
        let tools = [environment["BLOOM_REAL_GIT"], environment["BLOOM_REAL_GH"]]
            .compactMap { $0 }
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
        return (tools + ["/usr/local/bin", "/usr/bin", "/bin"]).reduce(into: [String]()) { result, directory in
            if !result.contains(directory) { result.append(directory) }
        }.joined(separator: ":")
    }

    /// Hides this process from anything that would read its memory, and **is called only once a
    /// token is already in hand**.
    ///
    /// The order is the whole of it. A non-dumpable process has its `/proc/<pid>` handed to root,
    /// and `exe`, `cwd` and `environ` then need CAP_SYS_PTRACE, which a Cloud workspace's machine
    /// does not grant to anyone. So a process that hides itself before asking for a credential
    /// cannot be identified by the supervisor that decides whether to give it one, and the whole
    /// exchange refuses itself: every private clone failed for a day as `process ancestry`, and it
    /// passed in CI because CI ran `--privileged` and had the capability.
    ///
    /// Hiding afterwards costs nothing. The reply only arrives once the supervisor has finished
    /// reading this process, so nothing holding a token is ever readable, and in the window before
    /// that there is no token to read. What the flag defends against is a reader of the same uid,
    /// since a different uid cannot read a dumpable process either, and the same uid is the same
    /// person, who is the one the credential belongs to.
    private static func makeCredentialProcessPrivate() -> Bool {
        #if os(Linux)
        return linuxPrctl(4, 0, 0, 0, 0) == 0 // PR_SET_DUMPABLE
        #else
        return true
        #endif
    }

    private static func ghRefused(_ reason: String, status: Int32) -> Int32 {
        FileHandle.standardError.write(Data("bloom-runner: gh-v2 refused: \(reason)\n".utf8))
        return status
    }

    private static func run(_ executable: String, _ arguments: [String], environment: [String: String]) async -> Int32 {
        #if os(Linux)
        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.compactMap { $0 }.forEach { free(UnsafeMutableRawPointer($0)) }
            envp.compactMap { $0 }.forEach { free(UnsafeMutableRawPointer($0)) }
        }
        _ = argv.withUnsafeBufferPointer { argumentBuffer in
            envp.withUnsafeBufferPointer { environmentBuffer in
                executable.withCString { path in
                    execve(path, argumentBuffer.baseAddress!, environmentBuffer.baseAddress!)
                }
            }
        }
        return 127
        #else
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return 127
        }
        #endif
    }
}
