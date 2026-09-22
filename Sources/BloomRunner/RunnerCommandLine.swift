import Foundation

/// `bloom-runner <command>`.
///
/// `serve` is the one a machine's service runs. The rest are what git and gh are pointed at on the
/// machine, so an agent's `git push` asks runbloom.app for a short-lived token through the server
/// rather than finding a long-lived one on disk.
public enum RunnerCommandLine {
    public static func run(_ arguments: [String]) async -> Int32 {
        switch arguments.first {
        case "serve":
            do {
                try await ServeCommand.run()
                return 0
            } catch {
                FileHandle.standardError.write(Data("bloom-runner: \(error)\n".utf8))
                return 1
            }
        case "git-credential-v2":
            return PersonBoundGitCommand.runCredentialHelper(Array(arguments.dropFirst()))
        case "git-v2":
            return await PersonBoundGitCommand.runGit(Array(arguments.dropFirst()))
        case "gh-v2":
            return await PersonBoundGitCommand.runGh(Array(arguments.dropFirst()))
        case "sandbox-exec":
            return PersonBoundSandboxExec.run(Array(arguments.dropFirst()))
        case "sandbox-peer-operation":
            return PersonBoundPeerOperation.runAttestor()
        case "sandbox-cleanup":
            return PersonBoundSandboxCleanup.run()
        case "sandbox-cleanup-stale":
            return PersonBoundSandboxCleanup.runStale()
        case "machine-identity-install":
            return MachineIdentityStateStore.runInstaller()
        case "version", "--version":
            print(RunnerVersion.current)
            return 0
        default:
            let usage = "usage: bloom-runner serve | git-credential-v2 get | git-v2 | gh-v2 | version\n"
            FileHandle.standardError.write(Data(usage.utf8))
            return 64
        }
    }
}
