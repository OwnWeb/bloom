import Foundation

/// What a Cloud workspace would lose if its machine went away now: work that exists nowhere else.
///
/// **Counts rather than a diff stat, because the diff stat answers a different question.** A
/// summary's `diff` is measured against the merge base, so it adds pushed commits, unpushed
/// commits, uncommitted changes and untracked files into one number. Above zero on nearly every
/// workspace, which makes an archive warning that is always on, and zero when a branch's commits
/// cancel out against the base, which is worse: those commits exist only on that machine and the
/// warning would say nothing is at stake.
///
/// Two git calls, both cheap enough for the summary's slow schedule: one `status --porcelain`, and
/// one `rev-list --count`. Against the branch's own remote when it has one, so a pushed branch
/// reports nothing unpushed, and against the base branch when it does not, because then every
/// commit on it is somewhere only this machine can see.
///
/// **Unknown is never zero.** Every caller of this gets nil when git could not be asked, and the
/// summary leaves the fields out rather than sending zeroes, because a zero reads as "nothing at
/// stake" and somebody will archive on the strength of it.
public struct RemoteWorkAtStake: Sendable, Hashable, Codable {
    /// Tracked files changed and not committed, staged or not.
    public var uncommitted: Int
    /// Files git has never seen, which are the easiest to lose.
    public var untracked: Int
    /// Commits on this branch that its remote does not have.
    public var unpushedCommits: Int

    public init(uncommitted: Int, untracked: Int, unpushedCommits: Int) {
        self.uncommitted = uncommitted
        self.untracked = untracked
        self.unpushedCommits = unpushedCommits
    }

    enum CodingKeys: String, CodingKey {
        case uncommitted, untracked
        case unpushedCommits = "unpushed_commits"
    }

    public var isEmpty: Bool { uncommitted == 0 && untracked == 0 && unpushedCommits == 0 }

    /// Nil when git could not answer, which the caller must not turn into zeroes.
    public static func measure(workspace: Workspace) async -> RemoteWorkAtStake? {
        guard FileManager.default.fileExists(atPath: workspace.path + "/.git"),
              let status = try? await Git.checkRaw(["status", "--porcelain", "-z"], in: workspace.path) else { return nil }
        var uncommitted = 0
        var untracked = 0
        for entry in Self.entries(String(decoding: status.stdout, as: UTF8.self)) {
            if entry.hasPrefix("??") { untracked += 1 } else { uncommitted += 1 }
        }
        guard let unpushed = await unpushedCommits(workspace: workspace) else { return nil }
        return RemoteWorkAtStake(uncommitted: uncommitted, untracked: untracked, unpushedCommits: unpushed)
    }

    /// `status -z` writes one NUL-terminated record per path, and a rename writes two: the entry
    /// and then the old path on its own. The old path is dropped rather than counted twice.
    static func entries(_ output: String) -> [String] {
        var entries: [String] = []
        var expectingOldPath = false
        for record in output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init) {
            if expectingOldPath {
                expectingOldPath = false
                continue
            }
            entries.append(record)
            expectingOldPath = record.hasPrefix("R") || record.hasPrefix("C")
        }
        return entries
    }

    /// Counted against the first of these that exists: the branch's own remote, the base branch's
    /// remote, the local base branch, and finally every commit there is. Each step down is a
    /// repository with less of a remote than the last, and the answer stays "what is only here"
    /// rather than becoming zero because the ref it asked for was missing.
    private static func unpushedCommits(workspace: Workspace) async -> Int? {
        guard Git.isValidBranchName(workspace.branch), Git.isValidBranchName(workspace.baseBranch) else { return nil }
        var candidates = [
            "refs/remotes/origin/" + workspace.branch,
            "refs/remotes/origin/" + workspace.baseBranch,
        ]
        // The local base branch only says something when it is not the branch itself: measuring
        // `main..HEAD` while HEAD is main answers zero for a repository whose every commit is
        // still only on this machine.
        if workspace.branch != workspace.baseBranch { candidates.append("refs/heads/" + workspace.baseBranch) }
        for ref in candidates {
            guard (try? await Git.run(["rev-parse", "--verify", "--quiet", ref], in: workspace.path))?.status == 0 else { continue }
            // The base branch's own commits are not at stake when HEAD is that branch.
            guard let counted = try? await Git.run(["rev-list", "--count", "\(ref)..HEAD"], in: workspace.path),
                  counted.ok, let count = Int(counted.trimmed) else { return nil }
            return count
        }
        guard let all = try? await Git.run(["rev-list", "--count", "HEAD"], in: workspace.path), all.ok,
              let count = Int(all.trimmed) else { return nil }
        return count
    }
}
