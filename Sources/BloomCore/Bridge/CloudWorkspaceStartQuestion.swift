import Foundation

/// The question Bloom itself asks before an agent's `cloud_workspace_start` reaches runbloom.app,
/// when the owner has left "Ask before an agent creates a Bloom Cloud workspace" on.
///
/// **Bloom's question, not the agent CLI's.** The CLI's own permission check asks or not depending
/// on the chat's permission mode, and a chat set to bypass permissions asks nobody, which is why
/// the settings pane could not promise the owner is asked. This one is asked by the window,
/// whatever the chat is set to, so with the setting on the promise is true and the pane makes it.
///
/// **On unless turned off**, because every one of these is a machine that costs money. The agents
/// switch still decides whether agents may ask at all; this decides whether each ask stops for a
/// person.
///
/// **Asked with what would be created**, after the project, the name and the branch are worked
/// out and before anything is spent, so the owner answers about the workspace rather than about
/// an agent's wish for one.
public struct CloudWorkspaceStartQuestion: Sendable, Equatable {
    /// The workspace and chat whose agent asked, when it asked from a workspace here. Nil for the
    /// owner's own client.
    public var requestedBy: String?
    public var name: String
    /// The runbloom.app project, as the owner knows it: its repository where there is one.
    public var project: String
    public var branch: String
    public var baseBranch: String
    public var runSetup: Bool

    public init(requestedBy: String?, name: String, project: String, branch: String, baseBranch: String, runSetup: Bool) {
        self.requestedBy = requestedBy
        self.name = name
        self.project = project
        self.branch = branch
        self.baseBranch = baseBranch
        self.runSetup = runSetup
    }

    /// The label the setting is shown under.
    public static let settingTitle = "Ask before an agent creates a Bloom Cloud workspace"

    /// Where it is kept. Absent means on: see the note on the type.
    public static let settingKey = "bridge.asksBeforeCloudWorkspaceStart"

    /// Whether to ask, from what the defaults hold under `settingKey`.
    public static func asks(stored: Any?) -> Bool {
        (stored as? Bool) ?? true
    }

    /// What the agent is told when the owner says no. Plain, and it tells the agent not to try
    /// its way round the answer.
    public static let declinedSentence = """
        The owner declined to create this Bloom Cloud workspace, and nothing was created. Do not \
        ask again unless the owner says so.
        """

    /// What the agent is told when Bloom is already asking about another one. One question at a
    /// time, because a pile of them behind each other is how a runaway agent gets a yes by fatigue.
    public static let busySentence = """
        Bloom is already asking the owner about another Bloom Cloud workspace. Wait for that answer \
        before asking for another.
        """

    public let title = "Create a Bloom Cloud workspace?"
    public let confirmLabel = "Create Workspace"
    public let cancelLabel = "Don't Create"

    public var message: String {
        let who = requestedBy.map { "An agent in \($0)" } ?? "An agent"
        let setup = runSetup ? "" : " It skips the project's setup."
        return "\(who) wants to create \u{201C}\(name)\u{201D} in \(project), on a new branch \(branch) from "
            + "\(baseBranch). It runs on a machine of its own, which costs money.\(setup)"
    }
}
