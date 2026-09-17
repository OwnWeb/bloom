import BloomClient
import BloomCore
import Observation

/// Who a Cloud workspace is shared with and its public preview links, while the share popover is
/// open. Only the owner changes any of it; runbloom.app says no to anybody else.
@MainActor
@Observable
final class CloudSharing {
    let workspaceID: CloudWorkspaceID
    let teamID: String
    @ObservationIgnored private let cloud: CloudWorkspaces

    private(set) var members: CloudWorkspaceMembers?
    private(set) var teamMembers: [RunbloomPerson] = []
    private(set) var hasReadTeam = false
    private(set) var shares: [PreviewShare] = []
    private(set) var isBusy = false
    var problem: String?

    init(workspaceID: CloudWorkspaceID, teamID: String, cloud: CloudWorkspaces) {
        self.workspaceID = workspaceID
        self.teamID = teamID
        self.cloud = cloud
    }

    /// Whether a collaborator has left the workspace's team. runbloom.app keeps their row, so the
    /// owner can remove them, and it gives them nothing while they are gone. Read against the team's
    /// members, and only once those were read: an empty list that failed to load is not a team
    /// everybody left.
    func hasLeftTeam(_ member: CloudWorkspaceMembers.Member) -> Bool {
        member.role != "owner" && hasReadTeam && !teamMembers.contains { $0.id == member.user.id }
    }

    /// Team members who are not in the workspace yet, for adding.
    var addable: [RunbloomPerson] {
        let present = Set(members?.members.map(\.user.id) ?? [])
        return teamMembers.filter { !present.contains($0.id) }
    }

    func load() async {
        await attempt {
            let api = cloud.api
            members = try await api.members(of: workspaceID.rawValue)
            shares = try await api.shares(of: workspaceID.rawValue)
            if let team = try? await api.teamMembers(team: teamID) {
                teamMembers = team
                hasReadTeam = true
            }
        }
    }

    func setSharedWithTeam(_ shared: Bool) async {
        await attempt { members = try await cloud.api.shareWithTeam(shared, workspace: workspaceID.rawValue) }
        await cloud.refresh(workspaceID)
    }

    func add(_ person: RunbloomPerson) async {
        await attempt { members = try await cloud.api.addCollaborator(person.id, to: workspaceID.rawValue) }
        await cloud.refresh(workspaceID)
    }

    func remove(_ member: CloudWorkspaceMembers.Member) async {
        await attempt {
            try await cloud.api.removeCollaborator(member.user.id, from: workspaceID.rawValue)
            members?.members.removeAll { $0.id == member.id }
        }
        await cloud.refresh(workspaceID)
    }

    func createShare() async -> PreviewShare? {
        var made: PreviewShare?
        await attempt {
            let share = try await cloud.api.createShare(for: workspaceID.rawValue)
            shares.insert(share, at: 0)
            made = share
        }
        return made
    }

    func revoke(_ share: PreviewShare) async {
        await attempt {
            try await cloud.api.revokeShare(share.id, of: workspaceID.rawValue)
            shares.removeAll { $0.id == share.id }
        }
    }

    private func attempt(_ work: () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await work()
            problem = nil
        } catch let refusal as RunbloomRefusal {
            problem = refusal.code == "no_team_agent_key"
                ? "\(refusal.message) A shared Cloud workspace runs every turn on the team's key, so the team needs one first."
                : refusal.message
        } catch {
            problem = "runbloom.app could not be reached. \(error.localizedDescription)"
        }
    }
}
