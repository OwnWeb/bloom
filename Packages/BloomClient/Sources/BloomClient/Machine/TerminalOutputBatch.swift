import Foundation

/// A Cloud terminal's output, gathered between two display refreshes and handed to the emulator
/// once.
///
/// **One frame of the machine's is one line of tmux's, and that is small.** The machine runs each
/// terminal under tmux in control mode and sends every `%output` line as a websocket frame of its
/// own. Measured through tmux 3.5 on this Mac: `seq 1 5000` came out as 849 frames, 83 bytes at the
/// median and 299 at most. The client fed each one to SwiftTerm as it arrived, and every feed is a
/// parse, a scroll and a redraw request, so a burst of output was eight hundred scrolls where the
/// screen can show sixty a second. That is the blank bands the owner saw while output was arriving,
/// and why they were the Cloud terminal's and not the local one's: a local pty is read in blocks
/// of kilobytes.
///
/// So bytes are appended as they come and taken once per refresh, which is as often as anybody can
/// see them. Nothing is reordered, dropped or split, so what the emulator parses is byte for byte
/// what the machine sent; only the number of times it is asked changes.
///
/// **Bounded, so a pane that is not being drawn cannot hold a flood.** A display refresh does not
/// come for a window that is hidden, so past `limit` the batch says to feed at once rather than
/// wait for one.
public struct TerminalOutputBatch: Sendable {
    /// Well above a refresh's worth of any real burst and well below a problem.
    public static let limit = 1 << 20

    private var pending = Data()
    /// How many frames are in `pending`, for the log line that says what the batching saved.
    public private(set) var frames = 0

    public init() {}

    public var isEmpty: Bool { pending.isEmpty }

    /// What to do with one frame.
    public enum Arrival: Equatable, Sendable {
        /// The first bytes since the last feed: ask for a refresh.
        case schedule
        /// A refresh has already been asked for.
        case wait
        /// Past the limit: feed now.
        case feedNow
    }

    public mutating func append(_ data: Data) -> Arrival {
        guard !data.isEmpty else { return .wait }
        let wasEmpty = pending.isEmpty
        pending.append(data)
        frames += 1
        if pending.count >= Self.limit { return .feedNow }
        return wasEmpty ? .schedule : .wait
    }

    /// Everything gathered, in order, leaving the batch empty.
    public mutating func take() -> (bytes: Data, frames: Int) {
        defer {
            pending = Data()
            frames = 0
        }
        return (pending, frames)
    }
}
