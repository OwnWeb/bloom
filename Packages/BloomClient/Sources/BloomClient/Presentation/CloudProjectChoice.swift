import Foundation

/// Which runbloom.app project an agent's `cloud_workspace_start` lands in.
///
/// **By repository, because that is what an agent standing in a workspace on this Mac has.** It
/// knows its own checkout; it does not know a runbloom.app project id. So a call that names no
/// project goes to the project whose repository is the caller's, and a call that names one may
/// name it by id or by the repository it is, `owner/name`.
///
/// **Refused rather than guessed wherever there is not exactly one.** The same repository can be a
/// project in two teams, and picking one of them would create a machine billed to a team the agent
/// never named. So two matches is a sentence asking for the id, and none is a sentence naming what
/// there is, both of which an agent can act on.
public enum CloudProjectChoice: Equatable, Sendable {
    case chosen(teamID: String, project: RunbloomProject)
    case refused(String)

    public struct Candidate: Sendable, Equatable {
        public var teamID: String
        public var teamName: String
        public var project: RunbloomProject

        public init(teamID: String, teamName: String, project: RunbloomProject) {
            self.teamID = teamID
            self.teamName = teamName
            self.project = project
        }
    }

    /// - Parameters:
    ///   - named: what the call said, an id or an `owner/name`, or nil.
    ///   - callerRepository: the caller's own repository, `owner/name`, or nil where the caller is
    ///     in no workspace or its repository is not on GitHub.
    ///   - candidates: every project in every team that can create Bloom Cloud workspaces.
    public static func choose(named: String?, callerRepository: String?, among candidates: [Candidate]) -> CloudProjectChoice {
        guard !candidates.isEmpty else {
            return .refused("None of your teams can create Bloom Cloud workspaces yet. runbloom.app says what each of them needs.")
        }
        if let named {
            let byID = candidates.filter { $0.project.id == named }
            if byID.count == 1, let only = byID.first { return .chosen(teamID: only.teamID, project: only.project) }
            return pick(repository: named, among: candidates, because: "named")
        }
        guard let callerRepository else {
            return .refused(
                "Name a project with 'project', because nothing else says where it should go. "
                    + "These can be used: \(listing(candidates))."
            )
        }
        return pick(repository: callerRepository, among: candidates, because: "is this workspace's repository")
    }

    private static func pick(repository: String, among candidates: [Candidate], because reason: String) -> CloudProjectChoice {
        let matches = candidates.filter { $0.project.repository.caseInsensitiveCompare(repository) == .orderedSame }
        switch matches.count {
        case 1:
            return .chosen(teamID: matches[0].teamID, project: matches[0].project)
        case 0:
            return .refused(
                "No Bloom Cloud project is \(repository), which \(reason). "
                    + "These can be used: \(listing(candidates))."
            )
        default:
            // Two teams with the same repository. Choosing one would bill a team nobody named.
            let teams = matches.map { "\($0.teamName) (\($0.project.id))" }.joined(separator: ", ")
            return .refused("\(repository) is a project in more than one team: \(teams). Name one with 'project', by its id.")
        }
    }

    private static func listing(_ candidates: [Candidate]) -> String {
        candidates.map { "\($0.project.repository) in \($0.teamName)" }.joined(separator: ", ")
    }
}
