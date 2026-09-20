import BloomCore
import Foundation

/// Caddy on the machine's URL port, kept running by Bloom Runner.
///
/// Started before setup, because the URL is how clients watch setup and a machine whose front
/// door opens only after a ten minute `prepare` looks broken for ten minutes. Restarted after a
/// crash with the same backoff as a service, and stopped with the rest of the machine.
public actor CaddySupervisor {
    public static let packagedExecutable = "/opt/bloom/current/bin/caddy"

    public struct Unavailable: Error, CustomStringConvertible {
        public let description = "Caddy is not installed: there is nothing at \(CaddySupervisor.packagedExecutable) and no caddy on PATH."
    }

    private let layout: MachineLayout
    private let configuration: CaddyConfiguration
    private let executable: String?
    private let backoff: RestartBackoff
    private let stopGrace: Duration
    private var process: SupervisedProcess?

    public init(
        layout: MachineLayout, publicURL: String, executable: String? = nil,
        backoff: RestartBackoff = .standard, stopGrace: Duration = .seconds(10)
    ) {
        self.layout = layout
        configuration = CaddyConfiguration(layout: layout, publicURL: publicURL)
        self.executable = executable
        self.backoff = backoff
        self.stopGrace = stopGrace
    }

    public nonisolated var directory: String { layout.dataDirectory + "/caddy" }
    public nonisolated var configurationPath: String { directory + "/Caddyfile" }
    public nonisolated var logPath: String { directory + "/caddy.log" }

    /// The packaged Caddy, else one on PATH, which is what a development machine has.
    public static func resolveExecutable(_ explicit: String? = nil) -> String? {
        if let explicit { return FileManager.default.isExecutableFile(atPath: explicit) ? explicit : nil }
        if FileManager.default.isExecutableFile(atPath: packagedExecutable) { return packagedExecutable }
        return Shell.which("caddy")
    }

    public func start() throws {
        guard process == nil else { return }
        guard let caddy = Self.resolveExecutable(executable) else { throw Unavailable() }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try configuration.render().write(toFile: configurationPath, atomically: true, encoding: .utf8)
        // Caddy keeps certificates and autosaved configuration under the XDG directories, which
        // default to the machine user's home. Nothing is saved with HTTPS and persistence off, but
        // if a later Caddy decides otherwise it lands here rather than in somebody's dotfiles.
        let environment = Shell.environment(extra: [
            "XDG_DATA_HOME": directory + "/data",
            "XDG_CONFIG_HOME": directory + "/config",
        ])
        let supervised = SupervisedProcess(
            command: .init(executable: caddy, arguments: ["run", "--config", configurationPath, "--adapter", "caddyfile"],
                           workingDirectory: directory, environment: environment),
            logPath: logPath, logLimit: 10 * 1_048_576, backoff: backoff, stopGrace: stopGrace
        ) { _ in }
        process = supervised
        supervised.start()
    }

    public func stop() async {
        let running = process
        process = nil
        await running?.stop()
    }
}
