import Foundation
import Observation
import BloomCore

/// The question Bloom asks before an agent's Bloom Cloud workspace is created, and the one place
/// that asks it. WHAT it asks is `CloudWorkspaceStartQuestion` in the core, where it is tested.
///
/// A shared presenter that `RootView` draws, rather than an `NSAlert`, for the reason
/// `SetupRunAlert` gives: a modal run loop stops every other workspace's transcript streaming for
/// as long as the question is up, and this one waits on a person.
///
/// **One question at a time.** A second ask while one is up is refused straight away rather than
/// queued behind it, so an agent asking in a loop meets one dialog and a refusal, not a stack of
/// dialogs to click through.
@MainActor
@Observable
final class CloudStartAlert {
    static let shared = CloudStartAlert()

    struct Request: Identifiable, Equatable {
        let id = UUID()
        var question: CloudWorkspaceStartQuestion

        static func == (lhs: Request, rhs: Request) -> Bool { lhs.id == rhs.id }
    }

    /// Non-nil while the dialog is up.
    var request: Request?

    @ObservationIgnored private var answer: CheckedContinuation<Bool, Never>?

    /// Whether the owner said yes. Nil when another question is already up.
    func ask(_ question: CloudWorkspaceStartQuestion) async -> Bool? {
        guard request == nil, answer == nil else { return nil }
        return await withCheckedContinuation { continuation in
            answer = continuation
            request = Request(question: question)
        }
    }

    func answered(_ yes: Bool) {
        request = nil
        let continuation = answer
        answer = nil
        continuation?.resume(returning: yes)
    }
}
