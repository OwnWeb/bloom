import Foundation

/// How a turn in a Cloud workspace came to rest, as the queue and runbloom.app need to know it.
///
/// Separate from `TurnEnding`, which decides the sentence under a transcript footer; this decides
/// what the queue does next. A failure pauses the queue behind it, so the next prompt from somebody
/// else is not fired into a chat whose last turn just fell over, and a stop does not.
public enum RemoteTurnEnd: Sendable, Hashable {
    case completed(String)
    case failed(String)
    case stopped(String)

    public var isFailure: Bool {
        if case .failed = self { true } else { false }
    }

    public var summary: String {
        switch self {
        case .completed(let text), .failed(let text), .stopped(let text): text
        }
    }
}
