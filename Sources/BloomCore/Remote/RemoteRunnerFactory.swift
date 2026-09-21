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
    public struct IsolatedLaunch: Sendable {
        public var launch: AgentLaunch
        public var cleanup: @Sendable () -> Void

        public init(launch: AgentLaunch, cleanup: @escaping @Sendable () -> Void) {
            self.launch = launch
            self.cleanup = cleanup
        }
    }

    public typealias Isolate = @Sendable (AgentLaunch) -> IsolatedLaunch
    public typealias Make = @Sendable (
        _ session: Session, _ workspacePath: String, _ store: Store, _ environment: [String: String],
        _ bridge: BridgeHandle?, _ context: RemoteLaunchContext?
    ) async throws -> any SessionRunner

    public static let live: Make = { session, workspacePath, store, environment, bridge, _ in
        make(session, workspacePath, store, environment, bridge, sandbox: nil)
    }

    /// **`sandbox` is what makes an ordinary launch unprivileged.** Nil runs it as this process's
    /// own user unless `isolate` supplies a stronger launch boundary. Every agent here spawns
    /// through an `AgentLaunch`, so one wrapping covers all four CLIs. See `MachineSandbox`, and H1
    /// in the security review of 19 September 2026.
    public static func make(_ session: Session, _ workspacePath: String, _ store: Store, _ environment: [String: String],
                            _ bridge: BridgeHandle?, sandbox: MachineSandbox?,
                            isolate: Isolate? = nil,
                            didStart: (@Sendable (Int32) -> Void)? = nil) -> any SessionRunner {
        let launching: @Sendable (AgentLaunch) -> any AgentProcessing = { launch in
            let wrapped = sandbox?.wrap(launch) ?? launch
            let isolated = isolate?(wrapped)
            let actual = isolated?.launch ?? wrapped
            return StreamingProcess(executable: actual.executable, arguments: actual.arguments, cwd: actual.cwd,
                                    environment: actual.environment, mergeStderr: false, didStart: didStart,
                                    cleanup: isolated?.cleanup)
        }
        switch session.agentKind {
        case .codex:
            return CodexRunner(workspacePath: workspacePath, session: session, store: store, bridge: bridge?.attachment) { configuration in
                var configuration = configuration
                configuration.environment.merge(environment) { _, extra in extra }
                if let sandbox { configuration.environment = sandbox.environment(configuration.environment) }
                return CodexClient(configuration: configuration, makeProcess: launching)
            }
        case .grok:
            return GrokRunner(workspacePath: workspacePath, session: session, store: store, bridge: bridge?.attachment) { configuration in
                var configuration = configuration
                configuration.environment.merge(environment) { _, extra in extra }
                if let sandbox { configuration.environment = sandbox.environment(configuration.environment) }
                return GrokClient(configuration: configuration, makeProcess: launching)
            }
        // Cursor and OpenCode have no runner, for the reason `TranscriptModel.makeRunner` gives.
        case .claudeCode, .cursor, .openCode:
            return AgentRunner(workspacePath: workspacePath, session: session, store: store, mcpConfigPath: bridge?.mcpConfigPath) { launch in
                launching(AgentLaunch(
                    executable: launch.executable, arguments: launch.arguments, cwd: launch.cwd,
                    environment: launch.environment.merging(environment) { _, extra in extra }
                ))
            }
        }
    }
}
