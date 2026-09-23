import BloomCore
import Foundation

/// How `git` and `gh` on the machine get a person-bound GitHub token from Bloom Runner.
///
/// Nothing long-lived is ever on disk. Git and gh are shadowed by wrappers in Bloom Runner's
/// protected `bin` directory. Both are written at every start, because the path to Bloom Runner is
/// part of what they say and an update can move it. See
/// docs/REMOTE-WORKSPACES.md, "GitHub".
///
struct MachineGitTools {
    var serverExecutable: String
    var repository: String
    var sharedDirectory: String = MachineSandbox.personBoundSharedDirectory
    var gitExecutable: String = Shell.which("git") ?? "/usr/bin/git"
    var ghExecutable: String = Shell.which("gh") ?? "/usr/bin/gh"
    var gitRemoteHTTPSExecutable: String = "/usr/lib/git-core/git-remote-https"

    var binDirectory: String {
        sharedDirectory + "/bin"
    }
    var ghWrapperPath: String { binDirectory + "/gh" }
    var gitWrapperPath: String { binDirectory + "/git" }

    /// The `gh` wrapper. It delegates to Bloom Runner, which validates the exact operation before
    /// running the root-attested gh executable with one operation-bound credential.
    var ghWrapper: String {
        return """
        #!/bin/sh
        # Written by Bloom Runner. The command classifies and fixes the repository before asking
        # the peer-authenticated Unix socket for one operation's credential.
        export BLOOM_REPOSITORY=\(Self.shellQuoted(repository))
        export BLOOM_BIN_DIR=\(Self.shellQuoted(binDirectory))
        export BLOOM_RUNNER_EXECUTABLE=\(Self.shellQuoted(serverExecutable))
        export BLOOM_REAL_GIT=\(Self.shellQuoted(gitExecutable))
        export BLOOM_REAL_GH=\(Self.shellQuoted(ghExecutable))
        export BLOOM_REAL_GIT_REMOTE_HTTPS=\(Self.shellQuoted(gitRemoteHTTPSExecutable))
        exec \(Self.shellQuoted(serverExecutable)) gh-v2 "$@"

        """
    }

    /// The `git` wrapper. Only a command that talks to GitHub goes through Bloom Runner; anything
    /// else is the real git, started directly.
    ///
    /// **Because going through Bloom Runner stops the whole sandbox.** The root supervisor pauses
    /// every other process in the launch while `git-v2` runs, so that nothing can read a token out
    /// of git's memory, and it holds them until that process exits. That is a few seconds for a
    /// push. For a `git commit` whose hook runs the test suite against a server in the same
    /// sandbox it is forever, because the server is one of the paused processes, and the agent
    /// that would time the command out is another. A local command carries no credential, so
    /// there is nothing to pause for. The parse only has to find the subcommand: getting it wrong
    /// sends a local command through `git-v2`, which runs it as plain git anyway, or a network one
    /// straight to git, which then has no credential and fails.
    var gitWrapper: String {
        let runner = Self.shellQuoted(serverExecutable)
        let git = Self.shellQuoted(gitExecutable)
        let network = PersonBoundGitCommand.networkGitCommands.sorted().joined(separator: "|")
        return """
        #!/bin/sh
        # Written by Bloom Runner. There is no legacy or SSH fallback in this v2 entry point.
        export BLOOM_REPOSITORY=\(Self.shellQuoted(repository))
        export BLOOM_BIN_DIR=\(Self.shellQuoted(binDirectory))
        export BLOOM_RUNNER_EXECUTABLE=\(runner)
        export BLOOM_REAL_GIT=\(git)
        export BLOOM_REAL_GH=\(Self.shellQuoted(ghExecutable))
        export BLOOM_REAL_GIT_REMOTE_HTTPS=\(Self.shellQuoted(gitRemoteHTTPSExecutable))
        # Only a command that reaches GitHub needs Bloom Runner, and going through it pauses the
        # rest of the sandbox while it runs, so everything else goes straight to git.
        skip=
        for argument in "$@"; do
            if [ -n "$skip" ]; then skip=; continue; fi
            case "$argument" in
                -C|-c|--git-dir|--work-tree|--namespace|--config-env|--super-prefix) skip=1 ;;
                -*) ;;
                \(network)) exec \(runner) git-v2 "$@" ;;
                *) exec \(git) "$@" ;;
            esac
        done
        exec \(git) "$@"

        """
    }

    func writeGhWrapper() throws {
        try FileManager.default.createDirectory(atPath: binDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binDirectory)
        try ghWrapper.write(toFile: ghWrapperPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ghWrapperPath)
        try gitWrapper.write(toFile: gitWrapperPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gitWrapperPath)
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
