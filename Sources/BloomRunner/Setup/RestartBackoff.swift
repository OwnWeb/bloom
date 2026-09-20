import Foundation

/// How long a crashed process waits before it is started again.
///
/// Doubling rather than a fixed pause, because a service that dies on start (a port taken, a
/// missing `.env`) would otherwise print the same stack trace into its log every second for as long
/// as the machine is awake, and every restart keeps a paused machine from sleeping. The reset after
/// a stable run is what stops one crash a day from leaving a healthy service waiting a minute.
public struct RestartBackoff: Sendable, Hashable {
    public var initial: Duration
    public var maximum: Duration
    /// A run at least this long counts as healthy, and the next crash waits `initial` again.
    public var stableAfter: Duration
    private var upcoming: Duration

    public init(initial: Duration, maximum: Duration, stableAfter: Duration) {
        self.initial = initial
        self.maximum = maximum
        self.stableAfter = stableAfter
        upcoming = initial
    }

    public static let standard = RestartBackoff(initial: .seconds(1), maximum: .seconds(60), stableAfter: .seconds(60))

    /// The wait before the next start, given how long the run that just ended lasted.
    public mutating func delay(afterRunningFor uptime: Duration) -> Duration {
        if uptime >= stableAfter { upcoming = initial }
        let delay = upcoming
        upcoming = min(upcoming * 2, maximum)
        return delay
    }
}
