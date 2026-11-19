import Foundation

/// Whether OpenCode has any provider to run a model on.
///
/// Its credentials are rows in its own database, so the only honest question is the one a chat
/// would ask: open a session. Measured on 2.3.2: with no provider, `session/new` fails with
/// `data.errorName: "CatalogNotReady"`; with Ollama as the only provider it succeeded in twenty
/// runs out of twenty, so a local provider detected late does not read as none.
public enum OpenCodeProviderCheck {
    static let noProviderErrorName = "CatalogNotReady"
    /// A cap on a server that never answers, not a measurement: a session opens in half a second.
    static let ceiling = Duration.seconds(30)

    /// True when a session opened, false when OpenCode said it has no model, nil when nothing was
    /// learnt. Only the measured error means "no provider": a crash or a timeout is not one.
    public static func hasProvider(
        executable: String,
        cwd: String = AgentScratchDirectory.current(),
        makeClient: @escaping @Sendable (OpenCodeClient.Configuration) -> OpenCodeClient = OpenCodeRunner.spawn
    ) async -> Bool? {
        let client = makeClient(OpenCodeClient.Configuration(executable: executable, cwd: cwd))
        // Killing the process fails every pending request, which is what ends the wait.
        let watchdog = Task {
            try await Task.sleep(for: ceiling)
            client.terminateNow()
        }
        defer {
            watchdog.cancel()
            Task { await client.stop() }
        }
        do {
            try await client.start()
            let session = try await client.newSession(cwd: cwd)
            await client.deleteSession(session.id)
            return true
        } catch {
            return verdict(for: error)
        }
    }

    static func verdict(for error: any Error) -> Bool? {
        guard let rpc = error as? ACPRPCError,
              rpc.data?["errorName"]?.stringValue == noProviderErrorName else { return nil }
        return false
    }
}
