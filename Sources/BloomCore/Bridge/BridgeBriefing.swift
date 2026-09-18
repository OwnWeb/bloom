import Foundation

/// What an agent is told about the place it is running, before it has to find out.
///
/// **Written because an agent spent thirty-five actions and two minutes proving something the
/// machine knew.** Asked to open a browser pane beside its chat, an agent on a Cloud machine ran
/// `which sprite-env`, searched the tool list, read `sprite-env --help`, listed
/// `/opt/bloom/current/bin`, grepped the repository for a port, read the settings file, read the
/// Caddyfile, disassembled `/.sprite/bin/sprite-browser`, tried it, and finally ran `strings` over
/// Bloom Runner's own binary looking for the word "browser". Every answer it reached was correct.
/// None of them was discoverable except by exhaustion.
///
/// **The tools are not the hard part; the shape of the place is.** `tools/list` already says what
/// exists, and the agent still could not tell that the absence of a pane tool was deliberate rather
/// than a gap it should route around. A pane belongs to the window of whoever is looking at the
/// workspace, and that window is on somebody's Mac, hundreds of miles from the machine. Nothing on
/// the machine can open one, and nothing on the machine said so.
///
/// Carried as MCP `instructions` on the initialize reply, which a client puts in front of the model
/// without it having to ask, and repeated in `whoami`, which is the tool an agent reaches for first
/// and the one this one did reach for.
public enum BridgeBriefing {
    /// The briefing for an agent on a Cloud workspace machine.
    ///
    /// Facts rather than advice, and only the ones that were expensive to work out: where it is,
    /// what it cannot do from here, how a person is actually shown a page, and which ports are
    /// already taken.
    public static func machine(publicURL: String, appPort: Int, reservedPorts: [(port: Int, holder: String)]) -> String {
        let ports = reservedPorts.map { "\($0.port) (\($0.holder))" }.joined(separator: ", ")
        return """
            You are running on a Cloud workspace machine, not on the owner's Mac.

            **Panes, terminals and browsers belong to whoever is looking at this workspace**, in \
            their own window, somewhere else. Nothing here can open, split or point one, and there \
            is no browser on this machine to drive. Where a tool for something is missing, that is \
            the answer rather than a gap to route around.

            **`request_pane` asks them to open a browser pane**, which is the most this end can \
            do. It reports how many clients were told, and tells you when there was nobody to ask, \
            because a machine often runs with every window shut. Do not say you opened anything.

            **A person is shown a page through the workspace's preview**, which is already there \
            and opens \(publicURL). It routes to whichever service `.bloom/settings.toml` marks \
            `http = true`, on port \(appPort), which is also `BLOOM_APP_PORT`. So the way to show \
            somebody something is to serve it there.

            **Ports already taken on this machine: \(ports).** `BLOOM_RESERVED_PORTS` carries the \
            list. A service that asks for one of them dies with "Address already in use" and \
            restarts for ever.

            **Before you touch `.bloom/settings.toml`, a setup script or a service, read \
            `cloud_setup`.** It is what runs and when, which ports are taken, what belongs in a \
            service rather than a script, and how to check. Everything in it was learned by \
            somebody losing an afternoon to it.

            To say something to the person rather than show them, write it in your answer: the \
            chat is what they are reading.
            """
    }

    /// The tool names, appended by `BridgeDispatch` so the list cannot drift from the toolbox it
    /// describes. An agent that has read this has no reason to probe for a tool that is not here.
    public static func tools(_ names: [String]) -> String {
        guard !names.isEmpty else { return "" }
        return "\n\nThe tools on this connection are the whole of what Bloom offers here: "
            + names.sorted().joined(separator: ", ") + "."
    }
}
