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
    private var began = false
    private var stepFile: CappedLogFile?
    private var dirty = false
    private var scheduledFlush: Task<Void, Never>?
    /// Set once the run is filed. A flush that had already woken when `finish` ran would otherwise
    /// apply `runStarted` again and reopen a finished run.
    private var finished = false

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
        add("[bloom] \(Self.title(name))")
    }

    func endStep() async {
        stepFile?.close()
        stepFile = nil
        await flush()
    }

    func append(_ line: String) {
        stepFile?.append(line)
        add(line)
    }

    /// A line for the row's log only, such as why a step was skipped.
    func note(_ line: String) {
        add("[bloom] " + line)
    }

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
            row.apply(.runInterrupted)
        }
    }

    private func close() {
        finished = true
        scheduledFlush?.cancel()
        scheduledFlush = nil
        stepFile?.close()
        stepFile = nil
    }

    private func add(_ line: String) {
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
        case "clone": "Cloning the repository."
        case "prepare": "Running the prepare script."
        case "setup": "Running the setup script."
        case "resume": "Running the resume script."
        default: step
        }
    }
}
