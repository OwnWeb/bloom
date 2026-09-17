import Foundation

/// The one place a Cloud workspace chat becomes an agent process.
///
/// The Mac decides this in `TranscriptModel.makeRunner`, in the app target, which the server does
/// not link. The difference that makes a second copy worth having is the environment: a turn's key
/// and the prompter's personal variables go into that process's environment and nowhere else, not
/// argv, not disk, not the transcript. Each runner already takes the factory it spawns through, so
/// the environment is merged there and no runner learns about keys.
///
/// The bridge handle is minted per process, by the runtime, for the same reason the Mac mints it
/// beside `makeRunner`: registering revokes the previous token for that chat, so it belongs where
/// the process it is for is decided. Nil means the chat runs with no bridge tools.
public enum RemoteRunnerFactory {
    public typealias Make = @Sendable (
        _ session: Session, _ workspacePath: String, _ store: Store, _ environment: [String: String], _ bridge: BridgeHandle?
    ) -> any SessionRunner

    public static let live: Make = { session, workspacePath, store, environment, bridge in
        switch session.agentKind {
        case .codex:
            return CodexRunner(workspacePath: workspacePath, session: session, store: store, bridge: bridge?.attachment) { configuration in
                var configuration = configuration
                configuration.environment.merge(environment) { _, extra in extra }
                return CodexRunner.spawn(configuration)
            }
        case .grok:
            return GrokRunner(workspacePath: workspacePath, session: session, store: store, bridge: bridge?.attachment) { configuration in
                var configuration = configuration
                configuration.environment.merge(environment) { _, extra in extra }
                return GrokRunner.spawn(configuration)
            }
        // Cursor and OpenCode have no runner, for the reason `TranscriptModel.makeRunner` gives.
        case .claudeCode, .cursor, .openCode:
            return AgentRunner(workspacePath: workspacePath, session: session, store: store, mcpConfigPath: bridge?.mcpConfigPath) { launch in
                AgentRunner.spawn(AgentLaunch(
                    executable: launch.executable, arguments: launch.arguments, cwd: launch.cwd,
                    environment: launch.environment.merging(environment) { _, extra in extra }
                ))
            }
        }
    }
}
