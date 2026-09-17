import Foundation
import Synchronization

/// A wall clock a test moves by hand, for anything that takes `now: @Sendable () -> Date`.
///
/// Starts at a fixed moment rather than the real one, so a token signed in a test and a clock
/// read in the same test cannot fall either side of a second boundary.
final class TestClock: Sendable {
    private let current: Mutex<Date>

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = Mutex(start)
    }

    var now: Date { current.withLock { $0 } }

    /// Hand this to the type under test.
    var reading: @Sendable () -> Date { { self.now } }

    func advance(by seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}
