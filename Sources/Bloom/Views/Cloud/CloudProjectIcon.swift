import BloomClient
import BloomCore
import SwiftUI

/// The shared Mac project mark fed by runbloom.app's authorised icon URL.
///
/// `RepoIcon` owns the rendering, including the adaptive border and the always-present initials.
/// This wrapper owns only the authenticated asynchronous load. It never derives a route or asks a
/// Cloud workspace's machine for anything.
struct CloudProjectIcon: View {
    var teamID: CloudTeamID
    var projectID: CloudProjectID
    var repository: String
    var iconURL: String?
    var localRepo: Repo?
    var size: CGFloat = Metrics.repoIcon
    /// Nil when the repository name is already beside the mark. Cloud workspace rows set this
    /// because their visible text is the workspace name, not the project name.
    var accessibilityName: String?

    @Environment(AppModel.self) private var app
    @State private var artwork: RepoArtwork?
    @State private var resolvedURL: String?

    private var key: CloudProjectIcons.Key { .init(teamID: teamID, projectID: projectID) }

    var body: some View {
        let displayedArtwork = artwork ?? localRepo.flatMap(RepoIconArt.artwork)
        RepoIcon(
            name: projectName, accent: nil, size: size,
            artwork: displayedArtwork,
            artworkKey: artwork == nil ? localRepo?.iconPath : resolvedURL
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityName ?? "")
        .accessibilityHidden(accessibilityName == nil)
        .task(id: requestKey) {
            artwork = nil
            resolvedURL = app.cloud.projectIcons.effectiveURL(for: key, listedURL: iconURL)
            let loaded = await app.cloud.projectIcons.artwork(for: key, listedURL: iconURL, api: app.cloud.api)
            guard !Task.isCancelled else { return }
            artwork = loaded
        }
    }

    private var projectName: String {
        repository.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? repository
    }

    private var requestKey: String {
        let revision = app.cloud.projectIcons.requestRevision(for: key)
        return "\(teamID):\(projectID):\(app.cloud.projectIcons.effectiveURL(for: key, listedURL: iconURL) ?? ""):\(revision):\(localRepo?.iconPath ?? "")"
    }
}
