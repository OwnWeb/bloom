import Foundation

/// The browser action a Cloud workspace may offer for its project settings.
///
/// The API and browser addresses are deliberately different fields. This accepts only the exact
/// absolute HTTP or HTTPS browser address runbloom.app sent. It does not add an access token,
/// cookie, query item or sign-in handoff; authentication belongs to the person's default browser.
public struct CloudProjectSettingsAction: Sendable, Hashable {
    public let url: URL

    public init?(project: CloudWorkspaceItem.ProjectReference?) {
        guard let value = project?.browserSettingsURL,
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url, url.absoluteString == value else { return nil }
        self.url = url
    }

    /// Opens through the app layer's default-browser action. Injected so the exact address can be
    /// verified without launching a browser in a test.
    public func open(using open: (URL) -> Void) {
        open(url)
    }
}
