import Foundation

/// How `git` and `gh` on the machine get a GitHub token: by asking Bloom Runner every time.
///
/// Nothing long-lived is ever on disk. git is given `bloom-runner git-credential` as its helper for
/// github.com, and `gh` is shadowed by a wrapper in Bloom Runner's own `bin` directory that asks
/// `bloom-runner gh-token` before every command. Both are written at every start, because the path
/// to Bloom Runner is part of what they say and an update can move it. See
/// docs/REMOTE-WORKSPACES.md, "GitHub".
///
/// **The locations are baked in, the turn is not.** `BLOOM_DATA_DIR` and `BLOOM_RUNNER_PORT` go
/// into the helper and the wrapper, so a shell somebody opens with none of Bloom's variables still
/// finds the server. `BLOOM_CHAT_ID`, `BLOOM_TERMINAL` and `BLOOM_TURN_ID` stay in the environment of whichever
/// process runs git, because they are what makes a push use the token of the person whose turn it
/// is.
struct MachineGitTools {
    var serverExecutable: String
    var dataDirectory: String
    var serverPort: Int
    var repository: String

    var binDirectory: String { dataDirectory + "/bin" }
    var ghWrapperPath: String { binDirectory + "/gh" }

    static let helperKey = "credential.https://github.com.helper"
    static let useHttpPathKey = "credential.https://github.com.useHttpPath"

    /// git's helper value. The `!` makes git run it through a shell, and git adds `get`, `store` or
    /// `erase` to the end.
    var credentialHelper: String {
        "!BLOOM_DATA_DIR=\(Self.shellQuoted(dataDirectory)) BLOOM_RUNNER_PORT=\(serverPort) "
            + "\(Self.shellQuoted(serverExecutable)) git-credential"
    }

    /// The `git config --global` invocations, in order. The empty helper first clears any helper a
    /// system-wide configuration set for github.com, such as one `gh auth setup-git` left behind,
    /// so git never tries a stored token before asking Bloom Runner.
    var configCommands: [[String]] {
        [
            ["config", "--global", "--unset-all", Self.helperKey],
            ["config", "--global", "--add", Self.helperKey, ""],
            ["config", "--global", "--add", Self.helperKey, credentialHelper],
            ["config", "--global", Self.useHttpPathKey, "true"],
        ]
    }

    /// The `gh` wrapper. The real `gh` is looked up when it runs rather than when it is written,
    /// because `prepare` may be what installs it, and `bin` itself is skipped so the wrapper cannot
    /// find itself. A failed token lookup still runs `gh`, since `gh --version` needs none and a
    /// command that does will say it is not signed in.
    var ghWrapper: String {
        """
        #!/bin/sh
        # Written by Bloom Runner at every start. Asks Bloom Runner for a short-lived GitHub token
        # for each command, so no token is stored on this machine.
        bloom_bin=\(Self.shellQuoted(binDirectory))
        real_gh=''
        saved_ifs=$IFS
        IFS=:
        for dir in $PATH; do
          if [ -z "$dir" ] || [ "$dir" = "$bloom_bin" ]; then continue; fi
          if [ -x "$dir/gh" ]; then real_gh="$dir/gh"; break; fi
        done
        IFS=$saved_ifs
        if [ -z "$real_gh" ]; then
          echo "gh is not installed on this machine." >&2
          exit 127
        fi
        GH_TOKEN="$(BLOOM_DATA_DIR=\(Self.shellQuoted(dataDirectory)) BLOOM_RUNNER_PORT=\(serverPort) BLOOM_REPOSITORY="${BLOOM_REPOSITORY:-\(repository)}" \(Self.shellQuoted(serverExecutable)) gh-token)"
        export GH_TOKEN
        exec "$real_gh" "$@"

        """
    }

    func writeGhWrapper() throws {
        try FileManager.default.createDirectory(atPath: binDirectory, withIntermediateDirectories: true)
        try ghWrapper.write(toFile: ghWrapperPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ghWrapperPath)
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
