import Foundation

/// Runs one client-requested Git or gh command through the same person-bound isolation boundary as
/// an agent turn. The grant stays an in-memory value and is never put in a process environment.
public struct RemotePublishing: Sendable {
    public typealias Run = @Sendable (
        _ executable: String, _ arguments: [String], _ cwd: String,
        _ context: RemoteLaunchContext
    ) async throws -> ShellResult

    public var run: Run

    public init(run: @escaping Run) {
        self.run = run
    }
}

extension WorkspaceRuntime {
    typealias PublishingCommand = @Sendable (
        _ executable: String, _ arguments: [String], _ cwd: String
    ) async throws -> ShellResult

    /// Registers one short-lived server turn and binds its grant to one isolated command.
    func asPerson<Value: Sendable>(
        _ caller: RemoteCaller,
        _ body: @Sendable (PublishingCommand?) async throws -> Value
    ) async throws -> Value {
        guard let publishing else { return try await body(nil) }
        let turnID = try await gate.register(.terminal, chat: nil, agent: nil, caller: caller)
        guard !turnID.isEmpty else {
            throw RemoteFailure(.unavailable, "No person-bound publishing turn was registered.")
        }
        let grant: RemoteTurnGrant
        do {
            grant = try await gate.start(turnID: turnID)
        } catch let refusal as RemoteTurnRefusal {
            await gate.end(turnID: turnID)
            switch refusal {
            case .blocked(let block): throw RemoteFailure(.limitReached, block.message)
            case .refused(_, let message): throw RemoteFailure(.invalidValue, message)
            }
        }
        guard let userID = caller.author?.userID, let githubGrant = grant.githubCredentialGrant else {
            await gate.end(turnID: turnID)
            throw RemoteFailure(
                .unavailable, "This publishing command has no person-bound GitHub credential grant."
            )
        }
        let context = RemoteLaunchContext(
            turnID: turnID, userID: userID, githubCredentialGrant: githubGrant
        )
        do {
            let value = try await body { executable, arguments, cwd in
                try await publishing.run(executable, arguments, cwd, context)
            }
            await gate.end(turnID: turnID)
            return value
        } catch {
            await gate.end(turnID: turnID)
            throw error
        }
    }

    func push(_ workspace: Workspace, command: PublishingCommand?) async throws {
        guard let command else {
            try await GitHub.push(
                worktree: workspace.path, branch: workspace.branch, setUpstream: true
            )
            return
        }
        guard Git.isValidBranchName(workspace.branch) else {
            throw RemoteFailure.invalid("This branch name is not one git accepts.")
        }
        let result = try await command(
            "git", ["push", "--set-upstream", "origin", "HEAD:refs/heads/\(workspace.branch)"],
            workspace.path
        )
        guard result.ok else {
            throw RemoteFailure(.gitFailed, result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    func createPullRequest(
        _ workspace: Workspace, title: String, body: String, draft: Bool,
        command: PublishingCommand?
    ) async throws -> String {
        guard let command else {
            return try await GitHub.createPullRequest(
                worktree: workspace.path, base: workspace.baseBranch, title: title, body: body,
                draft: draft
            ).url
        }
        guard Git.isValidBranchName(workspace.baseBranch) else {
            throw RemoteFailure.invalid("The base branch name is not one git accepts.")
        }
        var arguments = [
            "pr", "create", "--base", workspace.baseBranch, "--head", workspace.branch,
            "--title", title, "--body", body,
        ]
        if draft { arguments.append("--draft") }
        let result = try await command("gh", arguments, workspace.path)
        guard result.ok else {
            throw RemoteFailure(.gitFailed, result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return result.stdout.split(separator: "\n").last.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }
}
