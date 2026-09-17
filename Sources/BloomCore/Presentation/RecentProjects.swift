import Foundation

/// The projects most recently started in, newest first, which is the top of the create window's
/// project picker and the project that window opens on.
///
/// **Read off the workspaces rather than stored.** Every workspace row already carries the
/// project it was cut in and when, and an archived one keeps its row, so the newest `createdAt`
/// per project is the answer without a column that could drift from it. The one thing lost is a
/// project whose archived workspaces have been cleared out, which is a project nobody has started
/// in for a long time anyway.
///
/// **Workspaces an agent asked for do not count.** An agent calling `workspace_start` in a project
/// the owner has not looked at in months is not the owner choosing that project, and the window
/// opening on it the next time they press Cmd+N would look like a picker with a mind of its own.
public enum RecentProjects {
    /// How many the picker lists, few enough that the full list below still starts on screen.
    public static let limit = 10

    /// The projects in `repos` that have ever had a workspace started in them, newest first.
    ///
    /// Workspaces of a project no longer in `repos` are ignored, so a removed project cannot
    /// come back through its history.
    public static func ordered(_ repos: [Repo], workspaces: [Workspace], limit: Int = limit) -> [Repo] {
        var latest: [RepoID: Date] = [:]
        for workspace in workspaces where !workspace.origin.isAgentSpawned {
            latest[workspace.repoID] = max(latest[workspace.repoID] ?? .distantPast, workspace.createdAt)
        }

        let used = repos.compactMap { repo in latest[repo.id].map { (repo: repo, at: $0) } }
        let sorted = used.sorted { lhs, rhs in
            guard lhs.at == rhs.at else { return lhs.at > rhs.at }
            return lhs.repo.name.localizedStandardCompare(rhs.repo.name) == .orderedAscending
        }
        return sorted.prefix(limit).map(\.repo)
    }

    /// How many the sidebar's New menu offers, under its two generic items.
    public static let newMenuLimit = 5

    /// The New menu's "New workspace in" section: the same order, without hidden projects.
    ///
    /// Hidden before the cap rather than after, so five hidden projects at the top of the history
    /// cannot leave the section empty. Hiding is the owner saying a project is not worth the room,
    /// and a menu of five has less room than anywhere else a project is listed.
    public static func newMenu(_ repos: [Repo], workspaces: [Workspace]) -> [Repo] {
        ordered(repos.filter { !$0.hidden }, workspaces: workspaces, limit: newMenuLimit)
    }
}
