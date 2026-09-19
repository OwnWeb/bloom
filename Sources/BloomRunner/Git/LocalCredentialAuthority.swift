import BloomCore
import Foundation

/// Whose turn a local caller may have a GitHub token for.
///
/// **The caller is identified by what started it, never by what it says.** A chat id, a terminal
/// name or a turn id in the request is a claim; what decides is the pid the kernel reported for the
/// connection (`LocalCredentialSocket.Peer`) and what the Runner knows it started
/// (`SpawnedProcesses`, and tmux's own list of pane pids). This is M1 in the security review of
/// 19 September 2026, and the reason it cannot go back to reading `/proc/<pid>/environ` is the
/// sandbox: those processes run as another user, and their environment is theirs alone to read.
///
/// Nothing here refuses outright: an unrecognised caller gets the read-only installation token,
/// which is what setup, a service and anything else on the machine is meant to have.
enum LocalCredentialAuthority {
    /// What the door needs to know about the machine, injected so the rules can be tested without
    /// processes, tmux or runbloom.app.
    struct Surroundings: Sendable {
        /// What the caller descends from, of the things the Runner started itself.
        var origin: @Sendable (Int32) async -> SpawnedProcesses.Purpose?
        /// Every pid between the caller and the root, for matching a tmux pane.
        var ancestry: @Sendable (Int32) async -> [Int32]
        /// Each terminal's shell pid, by terminal name, as tmux reports it.
        var panePIDs: @Sendable () async -> [String: Int32]
        /// The runbloom.app turn a chat is running now.
        var runningTurn: @Sendable (String) async -> String?
        /// The turn of whichever connection to a terminal is open.
        var terminalTurn: @Sendable (String) async -> String?
        /// Whether a push or a pull request is running under a named turn.
        var isPublishing: @Sendable (String) async -> Bool
    }

    /// The turn to fetch a write token under, or nil for a read-only one.
    static func turn(for asked: GitCredentialRoute.Asked, peer: LocalCredentialSocket.Peer?,
                     in surroundings: Surroundings) async -> String? {
        // A named turn is the Runner's own push or pull request, and is accepted only while one is
        // running under it, as before. It needs no pid: the Runner started that command itself.
        if let named = asked.turnID, !named.isEmpty {
            return await surroundings.isPublishing(named) ? named : nil
        }
        // Everything else has to be somebody the kernel can name.
        guard let peer else { return nil }
        if let chat = asked.chatID, !chat.isEmpty {
            guard await surroundings.origin(peer.pid) == .chat(SessionID(chat)) else { return nil }
            return await surroundings.runningTurn(chat)
        }
        if let terminal = asked.terminal, !terminal.isEmpty {
            guard await surroundings.origin(peer.pid) == .terminalServer else { return nil }
            let panes = await surroundings.panePIDs()
            guard let pane = panes[terminal], await surroundings.ancestry(peer.pid).contains(pane) else { return nil }
            return await surroundings.terminalTurn(terminal)
        }
        return nil
    }
}
