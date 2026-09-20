import BloomCore
import Foundation

/// Where setup's output goes as it arrives: the workspace row's setup log, which is what clients
/// watch, and a file per step under the data directory, which is what survives the row's cap.
///
/// **Written while the run is going, not at its end.** The Mac holds a running setup's output in
/// its window and writes the row once, because the window is the only reader. On a machine the
/// readers are clients on the other end of an event stream, and the runtime publishes
/// `setupOutput` from the row's log growing, so the row has to grow. Writes are batched to a few a
/// second, because `composer install` prints thousands of lines and a transaction per line is a
/// database doing nothing else.
///
/// **Every write goes through `apply`,** as `SetupEvent.runProgressed(log:)`, which is legal only
/// while the row says `running`, so a late batch cannot land under a finished run's outcome.
actor SetupLog {
    private let store: Store
    private let workspaceID: WorkspaceID
    private let directory: String
    private var log = ""
    private var notes: [String] = []
    private var began = false
    private var stepFile: CappedLogFile?
    private var dirty = false
    private var scheduledFlush: Task<Void, Never>?
    /// Set once the run is filed. A flush that had already woken when `finish` ran would otherwise
    /// apply `runStarted` again and reopen a finished run.
    private var finished = false
    private var hidden: [String] = []

    /// The row's own cap, `Workspace.setupLogLimit`, which is internal to the core. Held here too
    /// so the text kept in memory cannot grow without bound during a long run.
    static let rowLimit = 200_000
    static let stepFileLimit = 20 * 1_048_576
    static let flushInterval = Duration.milliseconds(250)

    init(store: Store, workspaceID: WorkspaceID, directory: String) {
        self.store = store
        self.workspaceID = workspaceID
        self.directory = directory
    }

    var hasBegun: Bool { began }

    /// The notes taken so far, for a run that ends without anything having started.
    var text: String { log }

    /// Moves the row to `running`. A first-time setup starts the log afresh; a resume after a
    /// restart adds to the one setup left, so the account of how the workspace was made stays.
    func begin(continuing: Bool) async {
        guard !began else { return }
        began = true
        // Notes taken before anything ran, such as a settings problem, belong to this run.
        let earlier = log
        if continuing, let existing = try? await store.workspace(id: workspaceID)?.setupLog, !existing.isEmpty {
            log = (existing.hasSuffix("\n") ? existing : existing + "\n") + earlier
        } else {
            log = earlier
        }
        await write()
    }

    func startStep(_ name: String) {
        stepFile?.close()
        stepFile = CappedLogFile(path: directory + "/" + name + ".log", limit: Self.stepFileLimit)
        add(Self.marker + Self.title(name))
    }

    func endStep() async {
        stepFile?.close()
        stepFile = nil
        await flush()
    }

    /// A line a script printed.
    ///
    /// **A script cannot speak in Bloom's voice.** Clients style `[bloom] ` lines as Bloom's own
    /// sentences and one of them draws the newest as the row's note, so a script printing that
    /// prefix would put words of its choosing where a person reads Bloom's. Indented by one space
    /// instead: the line keeps every character it had and stops being at the start of a line, which
    /// is the whole of what the marker means.
    func append(_ line: String) {
        let masked = Self.masking(line, hiding: hidden)
        let safe = masked.hasPrefix(Self.marker) ? " " + masked : masked
        stepFile?.append(safe)
        add(safe)
    }

    /// **The team's and the project's values never reach the log.** Scripts get them in their
    /// environment, and a script that runs with `set -x` or prints its configuration writes them
    /// out, into a log every viewer of the workspace can read and that is kept on disk (L5 in the
    /// review of 19 September 2026). Each value is replaced wherever it appears in a line, longest
    /// first so one value inside another is not half shown. Values under `shortestHidden`
    /// characters are left, because masking `1` or `true` would hide every number and flag.
    func hide(_ values: some Sequence<String>) {
        hidden = Array(Set(values.filter { $0.count >= Self.shortestHidden })).sorted { $0.count > $1.count }
    }

    static let shortestHidden = 6
    static let mask = "******"

    static func masking(_ line: String, hiding values: [String]) -> String {
        values.reduce(line) { $0.replacingOccurrences(of: $1, with: mask) }
    }

    /// What every line Bloom writes itself begins with. See `docs/WORKSPACE-PROTOCOL.md`.
    static let marker = "[bloom] "

    /// A line for the row's log only, such as why a step was skipped.
    func note(_ line: String) {
        notes.append(line)
        add(Self.marker + line)
    }

    /// The notes on their own, for a run that is filed as skipped: the note replaces the log there,
    /// and **the whole log is the wrong thing to replace it with** now that naming the first phase
    /// means every run has a line or two in it before anything is decided.
    var noteText: String { notes.joined(separator: "\n") }

    func finish(succeeded: Bool) async {
        close()
        let text = log
        _ = try? await store.update(workspaceID: workspaceID) { row in
            row.apply(.runFinished(succeeded: succeeded, log: text))
        }
    }

    /// The machine is shutting down while a step runs. Filed as interrupted rather than failed:
    /// the step was stopped, it did not fail, and the next start runs it again.
    func interrupt() async {
        close()
        let text = log
        _ = try? await store.update(workspaceID: workspaceID) { row in
            row.apply(.runProgressed(log: text))
            row.apply(.runInterrupted(.machineStopped))
        }
    }

    private func close() {
        finished = true
        scheduledFlush?.cancel()
        scheduledFlush = nil
        stepFile?.close()
        stepFile = nil
    }

    /// When something was last written here, for the stall watchdog: a `setup` script that prints
    /// for twenty minutes is working, and a watchdog that called that a stall would say so four
    /// times about a machine doing exactly what it should.
    private(set) var lastWriteAt = Date()

    private func add(_ line: String) {
        lastWriteAt = Date()
        log += line + "\n"
        // Trimmed to three quarters rather than to the limit, so a log at the cap is not copied
        // whole again for every line that follows.
        if log.utf8.count > Self.rowLimit { log = String(log.suffix(Self.rowLimit * 3 / 4)) }
        dirty = true
        guard began, scheduledFlush == nil else { return }
        scheduledFlush = Task { [weak self] in
            try? await Task.sleep(for: Self.flushInterval)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    private func flush() async {
        scheduledFlush?.cancel()
        scheduledFlush = nil
        guard dirty else { return }
        await write()
    }

    private func write() async {
        guard !finished else { return }
        dirty = false
        let text = log
        _ = try? await store.update(workspaceID: workspaceID) { row in
            row.apply(.runStarted)
            row.apply(.runProgressed(log: text))
        }
    }

    static func title(_ step: String) -> String {
        switch step {
        case "environment": "Reading the team's environment."
        case "git": "Configuring git."
        case "services": "Starting the project's services."
        case "clone": "Cloning the repository."
        case "prepare": "Running the prepare script."
        case "setup": "Running the setup script."
        case "resume": "Running the resume script."
        default: step
        }
    }
}
