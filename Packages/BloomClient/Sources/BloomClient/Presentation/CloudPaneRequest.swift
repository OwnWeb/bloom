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

    /// Where the pane goes: beside the chat that asked, or in a tab.
    ///
    /// **The field exists because an agent asked to put a browser "next to this chat" and got a
    /// tab.** Locally those are two different verbs, `pane_split` and `pane_open`, and the event
    /// carried neither, so the thing the owner asked for was not expressible at all. Absent means
    /// `tab`, which is what every client did before the field existed, and an older client reading
    /// a word it does not know lands in the same place.
    ///
    /// **A split goes beside the pane showing the chat that asked, and only while that chat is on
    /// screen.** Otherwise a tab. The alternative is bringing that chat forward first, and moving
    /// somebody's selection because a machine mentioned another conversation is a bigger liberty
    /// than opening a pane: it takes away what they were reading, which opening a pane does not.
    /// The same reason the chat id has never been acted on for a tab.
    public static func placement(_ placement: String?, chatID: String?, isChatOnScreen: Bool) -> Placement {
        guard placement == "split", let chatID, isChatOnScreen else { return .tab }
        return .split(besideChat: chatID)
    }

    public enum Placement: Equatable, Sendable {
        case tab
        case split(besideChat: String)
    }

    /// What the reader is told, in every case including the ones that open nothing.
    ///
    /// **A pane that appears on its own owes an account of itself.** The owner is the only person
    /// who can tell a window he opened from one an agent in another country opened, and only if
    /// the app says so. The sentence names the workspace rather than the agent, because "the agent
    /// in Queue retries" is a thing he can go and look at.
    /// - Parameter placement: where it went, so the sentence does not say "beside the
    ///   conversation" about something that opened in a tab. An agent asking for a split whose
    ///   chat is not on screen gets a tab, and the reader is told which they got rather than which
    ///   was asked for: what they can see is the only thing worth describing to them.
    public static func sentence(
        _ request: CloudPaneRequest, workspace: String, placement: Placement = .tab
    ) -> String {
        let where_ = placement == .tab ? "in a tab" : "beside the conversation"
        switch request {
        case .workspaceApp:
            return "The agent in \(workspace) opened its app \(where_)."
        case .elsewhere(let url):
            return "The agent in \(workspace) asked to show \(url.absoluteString)."
        case .refused:
            return "The agent in \(workspace) asked to show an address Bloom cannot open."
        }
    }
}
