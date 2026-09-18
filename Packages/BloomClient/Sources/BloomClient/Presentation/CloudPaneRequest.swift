import Foundation

/// What a client does with a `pane_requested` event.
///
/// **A request from a machine is not a command, and this is where that is decided rather than
/// inside a view.** The agent asks; several clients may hear it; each answers for itself, and what
/// the agent is told is how many were asked rather than what any of them did. So there is no
/// outcome to send back and nothing to retry: what is left is one decision, which is what to show
/// the person sitting in front of it.
///
/// **Three answers, and the middle one is the one worth arguing about.** A request for the
/// workspace's own app is the pane that already exists for it, and opening it is the same act as
/// pressing Browser. A request for somewhere else is a different act: the pane over a Cloud
/// workspace is a window onto one machine by construction, reached through a token that lasts a
/// minute, and an agent naming `https://example.com` is asking Bloom to browse the web on its
/// behalf. That is not refused, because the page may be exactly what the reader asked the agent to
/// find, but it is offered rather than opened. And anything that is not http or https is refused
/// outright, which the machine already refuses before publishing; this is the second lock on the
/// same door, for the same reason `BrowserPaneTool` keeps one.
public enum CloudPaneRequest: Equatable, Sendable {
    /// The workspace's own app, at this path, or at its root where the request named none.
    case workspaceApp(path: String?)
    /// Somewhere else on the web, offered to the reader rather than opened for them.
    case elsewhere(URL)
    /// Nothing a browser pane may show.
    case refused

    /// - Parameters:
    ///   - url: what the machine asked for, or nil for the workspace's own address.
    ///   - machineHost: the host this workspace's machine answers on, as the session token names
    ///     it. Nil where no token has been fetched yet, which makes every named address somewhere
    ///     else: a client that cannot tell whose address it is must not assume it is the
    ///     machine's.
    public static func of(url: String?, machineHost: String?) -> CloudPaneRequest {
        guard let url, !url.trimmingCharacters(in: .whitespaces).isEmpty else { return .workspaceApp(path: nil) }
        guard let parts = URLComponents(string: url), let scheme = parts.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = parts.host, !host.isEmpty,
              let resolved = parts.url else { return .refused }
        guard let machineHost, host.caseInsensitiveCompare(machineHost) == .orderedSame else {
            return .elsewhere(resolved)
        }
        // The path and whatever follows it, which is what the agent is pointing at: the host is
        // the machine's and the client reaches it through its own exchange rather than through
        // this address, because that address carries no cookie and this one has no token in it.
        var path = parts.path
        if let query = parts.query, !query.isEmpty { path += "?" + query }
        if let fragment = parts.fragment, !fragment.isEmpty { path += "#" + fragment }
        let trimmed = path == "/" ? "" : path
        return .workspaceApp(path: trimmed.isEmpty ? nil : trimmed)
    }

    /// What the reader is told, in every case including the ones that open nothing.
    ///
    /// **A pane that appears on its own owes an account of itself.** The owner is the only person
    /// who can tell a window he opened from one an agent in another country opened, and only if
    /// the app says so. The sentence names the workspace rather than the agent, because "the agent
    /// in Queue retries" is a thing he can go and look at.
    public static func sentence(_ request: CloudPaneRequest, workspace: String) -> String {
        switch request {
        case .workspaceApp:
            "The agent in \(workspace) opened its app beside the conversation."
        case .elsewhere(let url):
            "The agent in \(workspace) asked to show \(url.absoluteString)."
        case .refused:
            "The agent in \(workspace) asked to show an address Bloom cannot open."
        }
    }
}
