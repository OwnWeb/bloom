import Foundation

/// What a backend with a runner still does not have.
///
/// `canRunWorkspaces` used to answer these two as well, because every backend with a runner had
/// both. OpenCode has a runner and neither, for reasons that are OpenCode's and are written in
/// `docs/OPENCODE.md`, so each question gets its own answer rather than a list of exceptions at
/// every call site.
public extension AgentKind {
    /// Whether the automatic router may ask this backend, or pick a model for a chat on it.
    ///
    /// The router needs one small, reliable model per backend. OpenCode's models are whatever
    /// providers the user connected, so there is none to name.
    var takesPartInRouting: Bool {
        canRunWorkspaces && self != .openCode
    }

    /// Whether a second sign in can be kept beside the first.
    ///
    /// OpenCode keeps its credentials in the directory that holds its session history, so a
    /// separate account would be a separate history.
    var hasAccountProfiles: Bool {
        canRunWorkspaces && self != .openCode
    }

    /// Whether a model or effort picked in the composer reaches the running process without
    /// starting it again.
    ///
    /// OpenCode sets both with `session/set_config_option` before every prompt, so a restart would
    /// only cost a server and a pty daemon. Grok sets them the same way but was never measured
    /// keeping a changed model across turns, so it still restarts.
    var takesComposerSettingsLive: Bool {
        self == .openCode
    }
}
