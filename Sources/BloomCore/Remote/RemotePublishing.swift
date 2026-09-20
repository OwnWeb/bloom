import Foundation

/// Pushing and opening pull requests from a client, as the person who asked.
///
/// **A push outside a turn gets no write token.** runbloom.app hands a machine a GitHub token that
/// can write only for a turn somebody started, so the Push button in a client is a turn of its own:
/// registered under the person's token as a terminal-kind session, started, used for the one
/// command, and ended. The command runs with `BLOOM_TURN_ID` in its environment, which is what the
/// credential helper asks with, and `gh` gets the token directly.
///
/// Without this (on a Mac, or in tests) the runtime pushes with whatever git and gh already have,
/// which is the Mac's behaviour.
public struct RemotePublishing: Sendable {
    /// A GitHub token for a turn, from runbloom.app.
    public var token: @Sendable (_ turnID: String) async throws -> String

    public init(token: @escaping @Sendable (_ turnID: String) async throws -> String) {
        self.token = token
    }
}

extension WorkspaceRuntime {
    /// Runs `body` inside a turn registered for the caller, handing it the environment a git or gh
    /// command needs to act as them.
    func asPerson<Value: Sendable>(_ caller: RemoteCaller, _ body: @Sendable ([String: String]) async throws -> Value) async throws -> Value {
        guard let publishing else { return try await body([:]) }
        let turnID = try await gate.register(.terminal, chat: nil, agent: nil, caller: caller)
        guard !turnID.isEmpty else { return try await body([:]) }
        do {
            _ = try await gate.start(turnID: turnID)
        } catch let refusal as RemoteTurnRefusal {
            await gate.end(turnID: turnID)
            switch refusal {
            case .blocked(let block): throw RemoteFailure(.limitReached, block.message)
            case .refused(_, let message): throw RemoteFailure(.invalidValue, message)
            }
        }
        publishingTurns.insert(turnID)
        defer { publishingTurns.remove(turnID) }
        do {
            let token = try await publishing.token(turnID)
            let value = try await body(["BLOOM_TURN_ID": turnID, "GH_TOKEN": token])
            await gate.end(turnID: turnID)
            return value
        } catch {
            await gate.end(turnID: turnID)
            throw error
        }
    }

    /// Whether a push or pull request is running under this turn now.
    public func isPublishingTurn(_ turnID: String) -> Bool {
        publishingTurns.contains(turnID)
    }

    func push(_ workspace: Workspace, environment: [String: String]) async throws {
        guard !environment.isEmpty else {
            try await GitHub.push(worktree: workspace.path, branch: workspace.branch, setUpstream: true)
            return
        }
        guard Git.isValidBranchName(workspace.branch) else { throw RemoteFailure.invalid("This branch name is not one git accepts.") }
        let result = try await Shell.run("git", ["push", "--set-upstream", "origin", "HEAD:refs/heads/\(workspace.branch)"],
                                         cwd: workspace.path, env: environment, timeout: .seconds(60))
        guard result.ok else { throw RemoteFailure(.gitFailed, result.stderr.isEmpty ? result.stdout : result.stderr) }
    }

    func createPullRequest(_ workspace: Workspace, title: String, body: String, draft: Bool, environment: [String: String]) async throws -> String {
        try await push(workspace, environment: environment)
        guard !environment.isEmpty else {
            return try await GitHub.createPullRequest(worktree: workspace.path, base: workspace.baseBranch, title: title, body: body, draft: draft).url
        }
        guard Git.isValidBranchName(workspace.baseBranch) else { throw RemoteFailure.invalid("The base branch name is not one git accepts.") }
        var arguments = ["pr", "create", "--base", workspace.baseBranch, "--head", workspace.branch, "--title", title, "--body", body]
        if draft { arguments.append("--draft") }
        let result = try await Shell.run("gh", arguments, cwd: workspace.path, env: environment, timeout: .seconds(60))
        guard result.ok else { throw RemoteFailure(.gitFailed, result.stderr.isEmpty ? result.stdout : result.stderr) }
        return result.stdout.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
    }
}
