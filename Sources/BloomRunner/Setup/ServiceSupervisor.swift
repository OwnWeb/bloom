import BloomCore
import Foundation

/// The project's `[[services]]`, run under Bloom Runner rather than as Sprite Services.
///
/// A Sprite Service restarts by itself on a cold wake, before `resume` has fetched fresh
/// environment, and cannot be deleted while another depends on it. So Bloom Runner is the only
/// Sprite Service, and it starts these after `resume`, in dependency order, with the environment
/// setup ran with. See docs/REMOTE-WORKSPACES.md, "Setup".
///
/// **A service is up when it runs, or when its ready check has passed if it has one.** A service
/// starts once everything it depends on is up, and stays running if a dependency crashes later:
/// restarting Vite because the app server restarted would only lose its connection to the browser.
/// A dependency whose check never passes leaves its dependents waiting, with a message saying
/// which one, because starting Horizon against a database that never came up only moves the error
/// somewhere harder to read.
public actor ServiceSupervisor {
    public enum State: String, Sendable, Hashable {
        /// Waiting for a dependency to be up.
        case waiting
        /// Running, and its ready check has not passed yet.
        case starting
        case running
        /// Running, and its ready check did not pass before the deadline.
        case notReady = "not_ready"
        /// Exited, and will be started again after a wait.
        case crashed
        case stopped
    }

    public struct Status: Sendable, Hashable {
        public var name: String
        public var state: State
        /// How many times it has exited since it was started.
        public var restarts: Int
        /// A sentence for a person: what it is waiting for, or how it ended.
        public var message: String?
    }

    public struct Tuning: Sendable, Hashable {
        public var readinessDeadline: Duration
        public var readinessInterval: Duration
        public var backoff: RestartBackoff
        public var stopGrace: Duration
        public var logLimit: Int

        public init(
            readinessDeadline: Duration = .seconds(300), readinessInterval: Duration = .milliseconds(500),
            backoff: RestartBackoff = .standard, stopGrace: Duration = .seconds(10), logLimit: Int = 10 * 1_048_576
        ) {
            self.readinessDeadline = readinessDeadline
            self.readinessInterval = readinessInterval
            self.backoff = backoff
            self.stopGrace = stopGrace
            self.logLimit = logLimit
        }

        public static let standard = Tuning()
    }

    private struct Entry {
        var service: RemoteProjectSettings.Service
        var state: State = .waiting
        var restarts = 0
        var message: String?
        var up = false
        var process: SupervisedProcess?
        var readiness: Task<Void, Never>?
    }

    private let layout: MachineLayout
    private let tuning: Tuning
    private var services: [RemoteProjectSettings.Service] = []
    private var environment: [String: String] = [:]
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    /// Bumped by every start and stop, so an event from a process that belonged to an earlier
    /// start cannot move the state of the one that replaced it.
    private var generation = 0

    public init(layout: MachineLayout, tuning: Tuning = .standard) {
        self.layout = layout
        self.tuning = tuning
    }

    public nonisolated var logDirectory: String { layout.dataDirectory + "/services" }

    public nonisolated func logPath(for name: String) -> String {
        logDirectory + "/" + Self.fileName(name) + ".log"
    }

    public var status: [Status] {
        order.compactMap { entries[$0] }.map { Status(name: $0.service.name, state: $0.state, restarts: $0.restarts, message: $0.message) }
    }

    /// Starts these services, stopping whatever was running first. A service with no name, or a
    /// second one under a name already taken, is left out; `RemoteProjectSettings.problems` has
    /// already said so.
    public func start(_ services: [RemoteProjectSettings.Service], environment: [String: String]) async {
        await stopAll()
        generation += 1
        self.services = services
        self.environment = environment
        entries = [:]
        order = []
        for service in services where !service.name.isEmpty && entries[service.name] == nil {
            entries[service.name] = Entry(service: service)
            order.append(service.name)
        }
        launchWhatIsReady()
    }

    /// Everything stopped and started again with this environment, which is what a changed team or
    /// project environment needs: a running process cannot be handed new variables.
    public func restartAll(environment: [String: String]) async {
        await start(services, environment: environment)
    }

    public func stopAll() async {
        generation += 1
        var stopping: [SupervisedProcess] = []
        for name in order {
            guard var entry = entries[name] else { continue }
            entry.readiness?.cancel()
            entry.readiness = nil
            if let process = entry.process { stopping.append(process) }
            entry.process = nil
            entry.up = false
            entry.state = .stopped
            entry.message = nil
            entries[name] = entry
        }
        // All at once, because each can take the whole grace period and ten services one after the
        // other would hold a machine that runbloom.app asked to stop for over a minute.
        await withTaskGroup(of: Void.self) { group in
            for process in stopping {
                group.addTask { await process.stop() }
            }
        }
    }

    private func launchWhatIsReady() {
        for name in order {
            guard var entry = entries[name], entry.state == .waiting, entry.process == nil else { continue }
            let missing = entry.service.dependsOn.filter { entries[$0]?.up != true }
            guard missing.isEmpty else {
                entry.message = "Waiting for \(missing.joined(separator: ", "))."
                entries[name] = entry
                continue
            }
            let generation = generation
            let process = SupervisedProcess(
                command: .init(executable: "/bin/sh", arguments: ["-c", entry.service.command],
                               workingDirectory: layout.worktree, environment: environment),
                logPath: logPath(for: name), logLimit: tuning.logLimit, backoff: tuning.backoff, stopGrace: tuning.stopGrace
            ) { [weak self] event in
                await self?.handle(event, service: name, generation: generation)
            }
            entry.process = process
            entry.state = .starting
            entry.message = nil
            entries[name] = entry
            process.start()
        }
    }

    private func handle(_ event: SupervisedProcess.Event, service name: String, generation: Int) {
        guard generation == self.generation, var entry = entries[name] else { return }
        entry.readiness?.cancel()
        entry.readiness = nil
        switch event {
        case .launched:
            if let ready = entry.service.ready, let url = ServiceReadiness.url(for: ready, appPort: layout.appPort) {
                entry.state = .starting
                entry.message = "Waiting for \(url) to answer."
                let tuning = tuning
                entry.readiness = Task { [weak self] in
                    let answered = await ServiceReadiness.wait(for: url, deadline: tuning.readinessDeadline, interval: tuning.readinessInterval)
                    guard !Task.isCancelled else { return }
                    await self?.readinessFinished(service: name, generation: generation, answered: answered, url: url)
                }
            } else {
                entry.state = .running
                entry.message = nil
                entry.up = true
            }
        case .exited(let status, let delay):
            entry.state = .crashed
            entry.restarts += 1
            entry.message = "Exited with status \(status). Starting again in \(SupervisedProcess.describe(delay))."
        }
        entries[name] = entry
        launchWhatIsReady()
    }

    private func readinessFinished(service name: String, generation: Int, answered: Bool, url: String) {
        guard generation == self.generation, var entry = entries[name], entry.state == .starting else { return }
        entry.readiness = nil
        if answered {
            entry.state = .running
            entry.message = nil
            entry.up = true
        } else {
            entry.state = .notReady
            entry.message = "Running, but \(url) did not answer within \(SupervisedProcess.describe(tuning.readinessDeadline))."
        }
        entries[name] = entry
        launchWhatIsReady()
    }

    /// A service name as a file name: a name is whatever the settings file says, and `../app` is
    /// not a log path.
    static func fileName(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let mapped = String(name.map { allowed.contains($0) ? $0 : "-" })
        return mapped.hasPrefix(".") ? "-" + mapped.dropFirst() : mapped
    }
}
