import BloomProtocol
import Foundation

/// What happened to a prompt somebody pressed send on, in the three answers that matter.
///
/// **The third one is the reason this is a type rather than an optional sentence.** A machine whose
/// runner died while an agent was already holding a prompt answers `outcome_unknown` on the retry:
/// it will not resolve it from the journal, because the alternative is running the same prompt
/// twice, so it pauses the chat and asks the person to look. Treated as a failure, the app takes
/// the words back into the composer and implies nothing was sent, and the obvious next thing
/// somebody does is send it again, which is exactly what the machine refused to do for them.
public enum CloudSendOutcome: Sendable, Hashable {
    case sent
    /// It did not go, and the words belong back in the composer.
    case failed(String)
    /// It may or may not have gone. The words are kept, and the sentence says so plainly.
    case unknown(String)

    public init(failure: WorkspaceConnection.CommandFailure?) {
        guard let failure else { self = .sent; return }
        self = failure.code == .outcomeUnknown ? .unknown(failure.message) : .failed(failure.message)
    }

    /// What a person is told, in the app's own voice, with the machine's own words after it.
    ///
    /// It says what is true rather than what is convenient: nobody knows, the chat is stopped
    /// until somebody looks, and the message is in the composer so nothing is lost either way.
    public var sentence: String? {
        switch self {
        case .sent: nil
        case .failed(let message): message
        case .unknown(let message):
            "Bloom does not know whether that message was sent: the workspace restarted while"
                + " it was being handed over. It has paused this chat and left the message in the"
                + " composer. Read the conversation before sending it again. \(message)"
        }
    }

    public var title: String {
        if case .unknown = self { "That message may already have been sent" } else { "Could not send the message" }
    }
}
