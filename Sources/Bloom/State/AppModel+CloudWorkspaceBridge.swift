import BloomClient
import BloomCore
import Foundation

/// The app's half of `cloud_workspace_start`: an order the tool has already checked, turned into
/// the same create the Bloom Cloud sheet makes.
///
/// **The sheet's rules, not a second set.** The name is `Git.title(from:)` of the prompt and the
/// branch is `Git.branchStem` under the account's GitHub login, which is what the sheet derives,
/// and `CloudBranchName` refuses the same branches it does. Which project is `CloudProjectChoice`,
/// in BloomClient where it is tested; what is here is reading the account and asking runbloom.app,
/// which nothing but the app can do.
///
/// Every failure is a sentence rather than a thrown error, because the reader is an agent that
/// will pass it on, and runbloom.app's own refusals already say what to do in words a person reads.
extension AppModel {
    func startCloudWorkspaceForBridge(_ order: CloudWorkspaceOrder) async -> CloudWorkspaceStartOutcome {
        guard let account = cloud.account else {
            return .refused("Bloom is not signed in to a Bloom account, so it cannot create Bloom Cloud workspaces. The owner signs in under Settings, Bloom Account.")
        }
        guard account.githubConnected else {
            return .refused("The Bloom account has no GitHub connected, which a Bloom Cloud workspace needs to clone and push. The owner connects it on runbloom.app.")
        }
        let teams = account.cloudTeams.filter { TeamSetupNotice(team: $0, environment: cloud.environment) == nil }

        var candidates: [CloudProjectChoice.Candidate] = []
        for team in teams {
            do {
                let projects = try await cloud.projects(team: team.id)
                candidates += projects.map { .init(teamID: team.id, teamName: team.name, project: $0) }
            } catch let refusal as RunbloomRefusal {
                return .refused(refusal.message)
            } catch {
                return .refused("runbloom.app could not be reached. \(error.localizedDescription)")
            }
        }

        let teamID: String, project: RunbloomProject
        switch CloudProjectChoice.choose(named: order.project, callerRepository: order.callerRepository, among: candidates) {
        case .chosen(let chosenTeam, let chosenProject): (teamID, project) = (chosenTeam, chosenProject)
        case .refused(let sentence): return .refused(sentence)
        }
        guard let team = cloud.team(teamID) else { return .refused("That team is no longer on the Bloom account.") }

        let prompt = order.prompt ?? ""
        let name = order.name ?? Git.title(from: prompt)
        let branch = order.branch ?? Git.branchStem(prompt: prompt.isEmpty ? name : prompt, prefix: account.branchPrefix)
        if let problem = CloudBranchName.problem(branch) {
            return .refused("'\(branch)' cannot be a branch. \(problem)")
        }

        do {
            let item = try await cloud.create(CloudWorkspaces.CreateRequest(
                team: team, project: project, name: name, branch: branch,
                baseBranch: order.baseBranch ?? project.defaultBranch, prompt: prompt, runSetup: order.runSetup
            ), selecting: false)
            // The address runbloom.app gave, passed through. Absent from an older server, and then
            // absent here too rather than built from a team slug and an id: it is somebody else's
            // routing.
            return .started(StartedCloudWorkspace(id: item.id, name: item.name, state: item.state, url: item.url))
        } catch let refusal as RunbloomRefusal {
            return .refused(LimitNotice(refusal: refusal).map { "\($0.message) \($0.detail)" } ?? refusal.message)
        } catch {
            return .refused("runbloom.app could not be reached. \(error.localizedDescription)")
        }
    }
}
