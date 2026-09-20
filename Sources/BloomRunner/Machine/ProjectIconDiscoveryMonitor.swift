import BloomCore
import Foundation

/// Keeps project-icon discovery in step with runbloom.app while this machine is running.
///
/// The authority is always loaded through the machine-authenticated client. A trigger carries no
/// project, repository path or revision, so neither a caller nor another workspace can choose what
/// this machine inspects. Concurrent triggers share one load and one worker. The highest accepted
/// authority, completion and exact prepared report are one durable record, so a restart cannot
/// regress a revision or re-render bytes whose PUT acknowledgement was lost.
public actor ProjectIconDiscoveryMonitor {
    public static let stateSetting = "remote.project-icon.completed"
    public static let detectorVersion = 1
    public static let pollInterval = Duration.seconds(300)

    public enum Outcome: Sendable, Equatable {
        case noRequest
        case stale
        case unsupportedDetector
        case alreadyReported
        case reported
        case retryPending
        case refused
        case stopped
    }

    public typealias LoadRequest = @Sendable () async throws -> ProjectIconRequestPoll
    public typealias Inspect = @Sendable (ProjectIconDiscoveryRequest, String) async throws -> ProjectIconInspection
    public typealias Report = @Sendable (ProjectIconReport) async throws -> Void
    public typealias LoadState = @Sendable () async throws -> String?
    public typealias SaveState = @Sendable (String) async throws -> Void
    public typealias Pause = @Sendable (Duration) async throws -> Void
    public typealias IsAwake = @Sendable () async -> Bool
    public typealias ObserveFailure = @Sendable (any Error) -> Void
    public typealias ObserveCoalesced = @Sendable () async -> Void

    private struct Prepared: Codable, Sendable, Equatable {
        var request: ProjectIconDiscoveryRequest
        var report: ProjectIconReport
    }

    private struct PersistentState: Codable, Sendable, Equatable {
        var version = 1
        var highestRevision = 0
        var latestRequest: ProjectIconDiscoveryRequest?
        var latestShouldDiscover: Bool?
        var noProjectAtHighestRevision = false
        var completed: ProjectIconDiscoveryRequest?
        var prepared: Prepared?

        static func decode(_ text: String) throws -> PersistentState {
            if text.first == "{" {
                let decoded = try JSONDecoder().decode(PersistentState.self, from: Data(text.utf8))
                guard decoded.version == 1,
                      (0...Int(UInt32.max)).contains(decoded.highestRevision),
                      decoded.latestRequest.map({ valid($0, noLaterThan: decoded.highestRevision) }) ?? true,
                      decoded.completed.map({ valid($0, noLaterThan: decoded.highestRevision) }) ?? true,
                      decoded.prepared.map({ prepared in
                          valid(prepared.request, noLaterThan: decoded.highestRevision)
                              && prepared.report.requestedRevision == prepared.request.requestedRevision
                              && prepared.report.detectorVersion == prepared.request.detectorVersion
                              && prepared.report.sourceCommit.range(
                                  of: "^[0-9a-f]{40}([0-9a-f]{24})?$", options: .regularExpression
                              ) != nil
                              && (prepared.report.icon.map(ProjectIconPNGNormalizer.isCanonical) ?? true)
                      }) ?? true,
                      validRelationships(decoded)
                else { throw ProjectIconMonitorError.invalidStoredState }
                return decoded
            }

            // The first 5C2 build stored only `detector:revision:branch`. Treat it as a completed
            // authority so an upgraded Runner cannot regress it before the first authenticated GET.
            let parts = text.split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3,
                  let detectorVersion = Int(parts[0]),
                  let requestedRevision = Int(parts[1]),
                  (1...Int(UInt32.max)).contains(requestedRevision),
                  (1...Int(UInt16.max)).contains(detectorVersion),
                  Git.isValidBranchName(parts[2])
            else { throw ProjectIconMonitorError.invalidStoredState }
            let completed = ProjectIconDiscoveryRequest(
                requestedRevision: requestedRevision,
                detectorVersion: detectorVersion,
                repositoryDefaultBranch: parts[2]
            )
            return PersistentState(
                highestRevision: requestedRevision,
                latestRequest: completed,
                latestShouldDiscover: false,
                completed: completed
            )
        }

        func encoded() throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(self)
            guard let text = String(data: data, encoding: .utf8) else {
                throw ProjectIconMonitorError.invalidStoredState
            }
            return text
        }

        private static func valid(_ request: ProjectIconDiscoveryRequest, noLaterThan highest: Int) -> Bool {
            (1...Int(UInt32.max)).contains(request.requestedRevision)
                && request.requestedRevision <= highest
                && (1...Int(UInt16.max)).contains(request.detectorVersion)
                && Git.isValidBranchName(request.repositoryDefaultBranch)
        }

        private static func validRelationships(_ state: PersistentState) -> Bool {
            if state.highestRevision == 0 {
                guard state.latestRequest == nil, state.completed == nil, state.prepared == nil else { return false }
                return state.noProjectAtHighestRevision
                    ? state.latestShouldDiscover == false
                    : state.latestShouldDiscover == nil
            }
            if let latest = state.latestRequest, latest.requestedRevision != state.highestRevision { return false }
            if state.noProjectAtHighestRevision {
                guard state.latestRequest == nil, state.latestShouldDiscover == false, state.prepared == nil else { return false }
            } else if state.latestRequest == nil || state.latestShouldDiscover == nil {
                return false
            }
            if state.latestShouldDiscover != true, state.prepared != nil { return false }
            if let prepared = state.prepared, prepared.request != state.latestRequest { return false }
            if let completed = state.completed, let latest = state.latestRequest,
               completed.requestedRevision == latest.requestedRevision, completed != latest {
                return false
            }
            if let completed = state.completed, let prepared = state.prepared,
               completed.requestedRevision == prepared.request.requestedRevision,
               completed != prepared.request {
                return false
            }
            return true
        }
    }

    private struct Active: Sendable {
        var id: UUID
        var task: Task<Outcome, Never>
    }

    private enum Trigger: Sendable, Equatable {
        case initial(ProjectIconDiscoveryRequest)
        case reload
        case scheduledReload

        var isReload: Bool {
            self == .reload || self == .scheduledReload
        }
    }

    private let repositoryPath: String
    private let supportedDetectorVersion: Int
    private let loadRequest: LoadRequest
    private let inspect: Inspect
    private let report: Report
    private let loadState: LoadState
    private let saveState: SaveState
    private let pause: Pause
    private let isAwake: IsAwake
    private let observeFailure: ObserveFailure
    private let observeCoalesced: ObserveCoalesced

    private var state = PersistentState()
    private var didLoadState = false
    private var active: Active?
    private var activeHasLoadedAuthority = false
    private var reloadOwed = false
    private var polling: Task<Void, Never>?
    private var pollingPause: Task<Void, Error>?
    private var nextPollAfter: Duration
    private var isStopped = false
    private var isTerminal = false
    private var refusalBackoff = false

    public init(
        repositoryPath: String,
        supportedDetectorVersion: Int = detectorVersion,
        pollInterval: Duration = ProjectIconDiscoveryMonitor.pollInterval,
        loadRequest: @escaping LoadRequest,
        inspect: @escaping Inspect = { request, repositoryPath in
            try await ProjectIconSnapshot.inspect(request, repositoryPath: repositoryPath)
        },
        report: @escaping Report,
        loadState: @escaping LoadState = { nil },
        saveState: @escaping SaveState = { _ in },
        pause: @escaping Pause = { try await Task.sleep(for: $0) },
        isAwake: @escaping IsAwake = { true },
        observeFailure: @escaping ObserveFailure = { _ in },
        observeCoalesced: @escaping ObserveCoalesced = {}
    ) {
        self.repositoryPath = repositoryPath
        self.supportedDetectorVersion = supportedDetectorVersion
        nextPollAfter = pollInterval
        self.loadRequest = loadRequest
        self.inspect = inspect
        self.report = report
        self.loadState = loadState
        self.saveState = saveState
        self.pause = pause
        self.isAwake = isAwake
        self.observeFailure = observeFailure
        self.observeCoalesced = observeCoalesced
    }

    /// Starts one bounded polling loop. Calling this twice does not create another worker.
    public func start(initialRequest: ProjectIconDiscoveryRequest?) {
        guard polling == nil, !isStopped else { return }
        polling = Task { [weak self] in
            guard let self else { return }
            if let initialRequest { _ = await self.perform(.initial(initialRequest)) }
            _ = await self.refresh()
            while !Task.isCancelled {
                guard await !self.hasTerminated else { break }
                guard await self.waitForNextPoll() else { continue }
                if await self.machineIsAwake() { _ = await self.perform(.scheduledReload) }
            }
        }
    }

    /// A wake bypasses the old schedule once, then starts a fresh server-provided interval.
    public func woke() async {
        guard polling != nil, !isStopped, !isTerminal else { return }
        let alreadyBackingOffRefusal = refusalBackoff
        _ = await refresh()
        // Cancel after the refresh has installed its interval. If the old timer expires while the
        // request is in flight, its refresh coalesces with this one and cannot issue a second GET.
        // A refusal newly installed by this wake must also replace the timer whose duration was
        // captured before the wake. An existing refusal keeps its five-minute timer intact.
        if !refusalBackoff || !alreadyBackingOffRefusal { pollingPause?.cancel() }
    }

    /// Reloads the request without accepting any authority from the trigger itself.
    @discardableResult
    public func refresh() async -> Outcome {
        await perform(.reload)
    }

    /// Cancels and awaits both the polling owner and any discovery or report in flight.
    public func stop() async {
        guard !isStopped else { return }
        isStopped = true
        let polling = self.polling
        let active = self.active?.task
        let pollingPause = self.pollingPause
        self.polling = nil
        self.active = nil
        self.pollingPause = nil
        reloadOwed = false
        polling?.cancel()
        pollingPause?.cancel()
        active?.cancel()
        _ = await active?.result
        _ = await pollingPause?.result
        _ = await polling?.result
    }

    private func perform(_ trigger: Trigger) async -> Outcome {
        guard !isStopped, !isTerminal else { return .stopped }
        if let active {
            if trigger.isReload, activeHasLoadedAuthority { reloadOwed = true }
            await observeCoalesced()
            return await active.task.value
        }

        let id = UUID()
        activeHasLoadedAuthority = false
        let task = Task { [weak self] in
            guard let self else { return Outcome.stopped }
            return await self.attempt(trigger)
        }
        active = Active(id: id, task: task)
        let outcome = await task.value
        if active?.id == id {
            active = nil
            activeHasLoadedAuthority = false
            if reloadOwed, !hasTerminated {
                reloadOwed = false
                if !refusalBackoff { return await perform(.reload) }
            }
        }
        return outcome
    }

    private func attempt(_ trigger: Trigger) async -> Outcome {
        guard !isStopped, !Task.isCancelled else { return .stopped }
        do {
            try await restoreState()
        } catch {
            return failure(error)
        }

        if refusalBackoff {
            guard trigger == .scheduledReload else { return .refused }
            refusalBackoff = false
        }

        // This was written before the PUT. It intentionally precedes a fresh GET: a lost PUT
        // acknowledgement must retry byte for byte after a restart. A successful reload still
        // performs the GET it promised, because 204 can mean the server ignored a stale report.
        if state.prepared != nil {
            let delivered = await deliverPrepared()
            guard delivered == .reported, trigger.isReload else { return delivered }
        }

        let projectIcon: MachineConfiguration.ProjectIcon?
        do {
            switch trigger {
            case .initial(let initial):
                activeHasLoadedAuthority = true
                projectIcon = MachineConfiguration.ProjectIcon(
                    requestedRevision: initial.requestedRevision,
                    detectorVersion: initial.detectorVersion,
                    repositoryDefaultBranch: initial.repositoryDefaultBranch,
                    shouldDiscover: true
                )
            case .reload, .scheduledReload:
                let response = try await loadRequest()
                activeHasLoadedAuthority = true
                nextPollAfter = response.pollAfter
                projectIcon = response.projectIcon
            }
        } catch is CancellationError {
            return .stopped
        } catch let error as ProjectIconRequestUnavailable {
            nextPollAfter = error.retryAfter
            observeFailure(error)
            return .retryPending
        } catch {
            return failure(error)
        }
        guard !isStopped, !Task.isCancelled else { return .stopped }
        return await accept(projectIcon)
    }

    private func accept(_ projectIcon: MachineConfiguration.ProjectIcon?) async -> Outcome {
        guard let projectIcon else {
            var updated = state
            updated.latestRequest = nil
            updated.latestShouldDiscover = false
            updated.noProjectAtHighestRevision = true
            updated.prepared = nil
            return await persist(updated, outcome: .noRequest)
        }
        guard let request = projectIcon.identityRequest else { return .refused }

        if request.requestedRevision < state.highestRevision { return .stale }
        if request.requestedRevision == state.highestRevision,
           let latestRequest = state.latestRequest,
           latestRequest != request {
            return .stale
        }
        let reopensResolvedRequest = state.latestShouldDiscover == false && projectIcon.shouldDiscover == true
        if request.requestedRevision == state.highestRevision,
           state.noProjectAtHighestRevision || reopensResolvedRequest {
            return .stale
        }

        var updated = state
        if request.requestedRevision > updated.highestRevision {
            updated.highestRevision = request.requestedRevision
            updated.latestRequest = request
            updated.latestShouldDiscover = projectIcon.shouldDiscover
            updated.noProjectAtHighestRevision = false
            updated.prepared = nil
        } else if updated.latestRequest == nil {
            updated.latestRequest = request
            updated.latestShouldDiscover = projectIcon.shouldDiscover
        }

        if projectIcon.shouldDiscover != true {
            updated.latestShouldDiscover = false
            updated.prepared = nil
            return await persist(updated, outcome: .noRequest)
        }
        guard request.detectorVersion == supportedDetectorVersion else {
            updated.prepared = nil
            return await persist(updated, outcome: .unsupportedDetector)
        }
        if let completed = updated.completed {
            if completed.requestedRevision > request.requestedRevision { return .stale }
            if completed == request { return .alreadyReported }
        }

        do {
            try await save(updated)
            try Task.checkCancellation()
            let inspection = try await inspect(request, repositoryPath)
            try Task.checkCancellation()
            guard state.latestRequest == request, state.latestShouldDiscover == true else { return .stale }
            var prepared = state
            prepared.prepared = Prepared(
                request: request,
                report: ProjectIconReport(
                    requestedRevision: request.requestedRevision,
                    detectorVersion: request.detectorVersion,
                    sourceCommit: inspection.sourceCommit,
                    icon: inspection.icon
                )
            )
            try await save(prepared)
            return await deliverPrepared()
        } catch is CancellationError {
            return .stopped
        } catch {
            return failure(error)
        }
    }

    private func deliverPrepared() async -> Outcome {
        guard let prepared = state.prepared else { return .alreadyReported }
        if let completed = state.completed,
           completed.requestedRevision > prepared.request.requestedRevision {
            var updated = state
            updated.prepared = nil
            return await persist(updated, outcome: .stale)
        }

        do {
            try Task.checkCancellation()
            try await report(prepared.report)
            try Task.checkCancellation()
            var completed = state
            if completed.completed.map({ $0.requestedRevision <= prepared.request.requestedRevision }) ?? true {
                completed.completed = prepared.request
            }
            completed.highestRevision = max(completed.highestRevision, prepared.request.requestedRevision)
            completed.prepared = nil
            try await save(completed)
            return .reported
        } catch is CancellationError {
            return .stopped
        } catch {
            return failure(error)
        }
    }

    private func restoreState() async throws {
        guard !didLoadState else { return }
        if let stored = try await loadState() { state = try PersistentState.decode(stored) }
        didLoadState = true
    }

    private func save(_ updated: PersistentState) async throws {
        guard updated != state else { return }
        try await saveState(updated.encoded())
        state = updated
    }

    private func persist(_ updated: PersistentState, outcome: Outcome) async -> Outcome {
        do {
            try await save(updated)
            return outcome
        } catch {
            return failure(error)
        }
    }

    private func failure(_ error: any Error) -> Outcome {
        observeFailure(error)
        guard let error = error as? RunbloomError else { return .retryPending }
        if error.isTerminal { isTerminal = true }
        if case .refused(let status, _, _, _, _) = error, status == 403 || status == 404 {
            nextPollAfter = .seconds(300)
            refusalBackoff = true
            reloadOwed = false
        }
        return error.isWorthRetrying ? .retryPending : .refused
    }

    private var hasTerminated: Bool { isStopped || isTerminal }

    private func machineIsAwake() async -> Bool { await isAwake() }

    private func waitForNextPoll() async -> Bool {
        guard !hasTerminated else { return false }
        let pause = self.pause
        let task = Task { try await pause(nextPollAfter) }
        pollingPause = task
        let result = await task.result
        pollingPause = nil
        return (try? result.get()) != nil
    }
}

enum ProjectIconMonitorError: Error, Sendable, Equatable {
    case invalidStoredState
}
