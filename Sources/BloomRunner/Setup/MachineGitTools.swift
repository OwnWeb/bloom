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

    var gitWrapper: String {
        """
        #!/bin/sh
        # Written by Bloom Runner. There is no legacy or SSH fallback in this v2 entry point.
        export BLOOM_REPOSITORY=\(Self.shellQuoted(repository))
        export BLOOM_BIN_DIR=\(Self.shellQuoted(binDirectory))
        export BLOOM_RUNNER_EXECUTABLE=\(Self.shellQuoted(serverExecutable))
        export BLOOM_REAL_GIT=\(Self.shellQuoted(gitExecutable))
        export BLOOM_REAL_GH=\(Self.shellQuoted(ghExecutable))
        export BLOOM_REAL_GIT_REMOTE_HTTPS=\(Self.shellQuoted(gitRemoteHTTPSExecutable))
        exec \(Self.shellQuoted(serverExecutable)) git-v2 "$@"

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
