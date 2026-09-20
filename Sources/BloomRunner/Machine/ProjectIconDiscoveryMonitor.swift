import Foundation

/// Keeps project-icon discovery in step with runbloom.app while this machine is running.
///
/// The authority is always loaded through the machine-authenticated client. A trigger carries no
/// project, repository path or revision, so neither a caller nor another workspace can choose what
/// this machine inspects. Concurrent triggers share one load and one worker. Failed reports retain
/// their exact prepared body, making a later attempt idempotent without inspecting a moving ref
/// twice for the same request.
public actor ProjectIconDiscoveryMonitor {
    public static let completedSetting = "remote.project-icon.completed"
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
    public typealias AlreadyReported = @Sendable (ProjectIconDiscoveryRequest) async throws -> Bool
    public typealias MarkReported = @Sendable (ProjectIconDiscoveryRequest) async throws -> Void
    public typealias Pause = @Sendable (Duration) async throws -> Void
    public typealias IsAwake = @Sendable () async -> Bool
    public typealias ObserveFailure = @Sendable (any Error) -> Void

    private struct Prepared: Sendable {
        var request: ProjectIconDiscoveryRequest
        var report: ProjectIconReport
    }

    private struct Active: Sendable {
        var id: UUID
        var task: Task<Outcome, Never>
    }

    private enum Trigger: Sendable {
        case initial(ProjectIconDiscoveryRequest)
        case reload
    }

    private let repositoryPath: String
    private let supportedDetectorVersion: Int
    private let loadRequest: LoadRequest
    private let inspect: Inspect
    private let report: Report
    private let alreadyReported: AlreadyReported
    private let markReported: MarkReported
    private let pause: Pause
    private let isAwake: IsAwake
    private let observeFailure: ObserveFailure

    private var latestRequest: ProjectIconDiscoveryRequest?
    private var latestShouldDiscover: Bool?
    private var noProjectAtHighestRevision = false
    private var highestRevision = 0
    private var prepared: Prepared?
    private var completed: ProjectIconDiscoveryRequest?
    private var active: Active?
    private var activeHasLoadedAuthority = false
    private var reloadOwed = false
    private var polling: Task<Void, Never>?
    private var pollingPause: Task<Void, Error>?
    private var nextPollAfter: Duration
    private var isStopped = false
    private var isTerminal = false

    var hasQueuedRefresh: Bool { reloadOwed }

    public init(
        repositoryPath: String,
        supportedDetectorVersion: Int = detectorVersion,
        pollInterval: Duration = ProjectIconDiscoveryMonitor.pollInterval,
        loadRequest: @escaping LoadRequest,
        inspect: @escaping Inspect = { request, repositoryPath in
            try await ProjectIconSnapshot.inspect(request, repositoryPath: repositoryPath)
        },
        report: @escaping Report,
        alreadyReported: @escaping AlreadyReported = { _ in false },
        markReported: @escaping MarkReported = { _ in },
        pause: @escaping Pause = { try await Task.sleep(for: $0) },
        isAwake: @escaping IsAwake = { true },
        observeFailure: @escaping ObserveFailure = { _ in }
    ) {
        self.repositoryPath = repositoryPath
        self.supportedDetectorVersion = supportedDetectorVersion
        nextPollAfter = pollInterval
        self.loadRequest = loadRequest
        self.inspect = inspect
        self.report = report
        self.alreadyReported = alreadyReported
        self.markReported = markReported
        self.pause = pause
        self.isAwake = isAwake
        self.observeFailure = observeFailure
    }

    /// Starts one bounded polling loop. Calling this twice does not create another worker.
    public func start(initialRequest: ProjectIconDiscoveryRequest?) {
        guard polling == nil, !isStopped else { return }
        polling = Task { [weak self] in
            guard let self else { return }
            if let initialRequest {
                _ = await self.perform(.initial(initialRequest))
            }
            _ = await self.refresh()
            while !Task.isCancelled {
                guard await !self.hasTerminated else { break }
                guard await self.waitForNextPoll() else { continue }
                if await self.machineIsAwake() { _ = await self.refresh() }
            }
        }
    }

    /// A wake bypasses the old schedule once, then starts a fresh server-provided interval.
    public func woke() async {
        guard polling != nil, !isStopped, !isTerminal else { return }
        _ = await refresh()
        // Cancel after the refresh has installed its interval. If the old timer expires while the
        // request is in flight, its refresh coalesces with this one and cannot issue a second GET.
        pollingPause?.cancel()
    }

    /// Reloads the request without accepting any authority from the trigger itself.
    ///
    /// Reentrant callers observe the same task, so bursts from polling and a future authenticated
    /// control hint coalesce into one server read and one discovery attempt.
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
        reloadOwed = false
        self.pollingPause = nil
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
            if case .reload = trigger, activeHasLoadedAuthority { reloadOwed = true }
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
                return await perform(.reload)
            }
        }
        return outcome
    }

    private func attempt(_ trigger: Trigger) async -> Outcome {
        guard !isStopped, !Task.isCancelled else { return .stopped }
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
            case .reload:
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
        } catch let error as RunbloomError {
            observeFailure(error)
            if error.isTerminal { isTerminal = true }
            if case .refused(let status, _, _, _, _) = error, status == 403 || status == 404 {
                nextPollAfter = .seconds(300)
            }
            return error.isWorthRetrying ? .retryPending : .refused
        } catch {
            observeFailure(error)
            return .retryPending
        }
        guard !isStopped, !Task.isCancelled else { return .stopped }
        guard let projectIcon else {
            latestRequest = nil
            latestShouldDiscover = false
            noProjectAtHighestRevision = true
            prepared = nil
            return .noRequest
        }
        guard let request = projectIcon.identityRequest else { return .refused }

        if request.requestedRevision < highestRevision { return .stale }
        if request.requestedRevision == highestRevision,
           let latestRequest,
           latestRequest != request {
            return .stale
        }
        if request.requestedRevision == highestRevision,
           noProjectAtHighestRevision || (latestShouldDiscover == false && projectIcon.shouldDiscover == true) {
            return .stale
        }
        if request.requestedRevision > highestRevision {
            highestRevision = request.requestedRevision
            latestRequest = request
            latestShouldDiscover = projectIcon.shouldDiscover
            noProjectAtHighestRevision = false
            prepared = nil
        } else if latestRequest == nil {
            latestRequest = request
            latestShouldDiscover = projectIcon.shouldDiscover
        }

        guard projectIcon.shouldDiscover == true else {
            latestShouldDiscover = false
            prepared = nil
            return .noRequest
        }

        guard request.detectorVersion == supportedDetectorVersion else {
            prepared = nil
            return .unsupportedDetector
        }
        if completed == request { return .alreadyReported }

        do {
            if try await alreadyReported(request) {
                completed = request
                prepared = nil
                return .alreadyReported
            }
            try Task.checkCancellation()

            let prepared: Prepared
            if let cached = self.prepared, cached.request == request {
                prepared = cached
            } else {
                let inspection = try await inspect(request, repositoryPath)
                try Task.checkCancellation()
                guard latestRequest == request else { return .stale }
                prepared = Prepared(
                    request: request,
                    report: ProjectIconReport(
                        requestedRevision: request.requestedRevision,
                        detectorVersion: request.detectorVersion,
                        sourceCommit: inspection.sourceCommit,
                        icon: inspection.icon
                    )
                )
                self.prepared = prepared
            }

            try await report(prepared.report)
            try Task.checkCancellation()
            guard latestRequest == request else { return .stale }
            try await markReported(request)
            completed = request
            self.prepared = nil
            return .reported
        } catch is CancellationError {
            return .stopped
        } catch let error as RunbloomError {
            observeFailure(error)
            if error.isTerminal { isTerminal = true }
            return error.isWorthRetrying ? .retryPending : .refused
        } catch {
            observeFailure(error)
            return .retryPending
        }
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
