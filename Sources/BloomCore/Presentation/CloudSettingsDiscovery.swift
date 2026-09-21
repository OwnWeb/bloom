import Foundation

/// The hidden route to Bloom Cloud settings while the service is private.
///
/// Ten uninterrupted taps on General inside one ten second window reveal the pane. Any other
/// settings row breaks the sequence, so ordinary navigation can never unlock it by accident.
public struct CloudSettingsDiscovery: Sendable {
    private var count = 0
    private var startedAt: Date?

    public init() {}

    public static func isVisible(isSignedIn: Bool, isRevealed: Bool) -> Bool {
        isSignedIn || isRevealed
    }

    /// Records one settings row tap and answers whether this tap completed the hidden sequence.
    public mutating func record(isGeneral: Bool, at date: Date) -> Bool {
        guard isGeneral else {
            reset()
            return false
        }

        guard let startedAt else {
            self.startedAt = date
            count = 1
            return false
        }

        let elapsed = date.timeIntervalSince(startedAt)
        guard elapsed >= 0, elapsed <= 10 else {
            self.startedAt = date
            count = 1
            return false
        }

        count += 1
        guard count == 10 else { return false }
        reset()
        return true
    }

    private mutating func reset() {
        count = 0
        startedAt = nil
    }
}
