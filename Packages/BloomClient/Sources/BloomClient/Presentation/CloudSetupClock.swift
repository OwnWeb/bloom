import Foundation

/// When each of a new Cloud workspace's steps began and ended, as far as this client saw.
///
/// **The machine does not send a time per step**, only when the whole run started and finished,
/// so these are the moments this window watched the current step change. That makes them honest
/// only where the change was actually watched: a step that was already running when the window
/// opened has no start here, and draws no time rather than a wrong one. Somebody who reopens the
/// workspace two minutes into its setup script is not told the script has been running for three
/// seconds.
///
/// Two starts are known without having been watched, and are passed in as anchors: the machine
/// began being made when the workspace was created, and the clone began when the run did.
public struct CloudSetupClock: Equatable, Sendable {
    private var current: CloudSetupProgress.StepID?
    private var starts: [CloudSetupProgress.StepID: Date] = [:]
    private var ends: [CloudSetupProgress.StepID: Date] = [:]

    public init() {}

    /// Records that `step` is the one running now. The same step again changes nothing, so this
    /// can be called on every change of what is drawn.
    public mutating func observe(_ step: CloudSetupProgress.StepID?, at now: Date) {
        guard step != current else { return }
        if let current {
            ends[current] = now
            // Only a step that followed one this window saw end has a start it can vouch for.
            if let step { starts[step] = now }
        }
        current = step
    }

    /// When `step` began, if it is known.
    public func start(of step: CloudSetupProgress.StepID, anchors: [CloudSetupProgress.StepID: Date] = [:]) -> Date? {
        starts[step] ?? anchors[step]
    }

    /// How long a finished step took, if both of its ends are known.
    public func duration(
        of step: CloudSetupProgress.StepID, anchors: [CloudSetupProgress.StepID: Date] = [:]
    ) -> TimeInterval? {
        guard let start = start(of: step, anchors: anchors), let end = ends[step], end >= start else { return nil }
        return end.timeIntervalSince(start)
    }
}
