import Foundation

/// A sentence above the composer, with the one way forward it has.
///
/// It exists for the state a Cloud workspace can be in before anybody types: the team has no API
/// key for this agent, or GitHub is not connected, so runbloom.app would refuse the turn a minute
/// later with the same sentence and nothing to press. A local workspace has no such state and
/// answers nil, which is why this is data rather than a view: the composer draws it, and neither
/// kind of workspace knows how.
struct ChatComposerNotice: Equatable {
    var sentence: String
    /// The title of the button beside it, or nil for a sentence with nothing to do about it.
    var actionTitle: String?
    /// Compared by title alone, because a closure is not equatable and two notices with the same
    /// words and the same button are the same notice as far as a redraw is concerned.
    var action: (() -> Void)?

    init(sentence: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.sentence = sentence
        self.actionTitle = actionTitle
        self.action = action
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sentence == rhs.sentence && lhs.actionTitle == rhs.actionTitle
    }
}
