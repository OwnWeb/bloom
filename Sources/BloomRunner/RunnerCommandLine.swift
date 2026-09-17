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
        case "git-credential", "gh-token":
            return await GitCredentialCommand.run(arguments)
        case "version", "--version":
            print(RunnerVersion.current)
            return 0
        default:
            let usage = "usage: bloom-runner serve | git-credential get | gh-token | version\n"
            FileHandle.standardError.write(Data(usage.utf8))
            return 64
        }
    }
}
