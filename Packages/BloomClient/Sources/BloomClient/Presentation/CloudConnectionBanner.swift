import Foundation

/// The line over an open Cloud workspace that says where its connection is, or nothing.
///
/// **Silent for the first half second.** A machine that is awake answers in a fraction of that, and
/// a banner that flashes up and away on every open reads as a fault. After half a second a machine
/// last seen asleep is said to be waking, in words, rather than shown as a spinner with nothing to
/// explain it: the first request after a pause measured 4.5 seconds.
public struct CloudConnectionBanner: Sendable, Hashable {
    public enum Tone: Sendable, Hashable {
        /// Something is happening and will finish by itself.
        case progress
        /// Nothing is wrong, but nothing is happening either until somebody acts or something clears.
        case caution
        /// It will not carry on without a person.
        case failure
    }

    public var tone: Tone
    public var title: String
    public var message: String?
    /// The button's label, when the banner offers one: waking a sleeping machine, trying a refused
    /// wake again.
    public var action: String?

    public init(tone: Tone, title: String, message: String? = nil, action: String? = nil) {
        self.tone = tone
        self.title = title
        self.message = message
        self.action = action
    }

    public static func of(_ phase: WorkspaceConnection.Phase) -> CloudConnectionBanner? {
        switch phase {
        case .closed, .live, .connecting(waking: false):
            return nil
        case .connecting(waking: true):
            return CloudConnectionBanner(tone: .progress, title: "Waking this Cloud workspace…", message: "It was asleep. This usually takes a few seconds.")
        case .asleep:
            return CloudConnectionBanner(
                tone: .caution, title: "This Cloud workspace is asleep",
                message: "It went to sleep because nobody was using it. It wakes as soon as you do something in it.", action: "Wake"
            )
        case .notReady(let message, _):
            return CloudConnectionBanner(tone: .progress, title: "Starting this Cloud workspace…", message: message)
        case .limited(let notice):
            return CloudConnectionBanner(
                tone: notice.kind == .waiting ? .caution : .failure, title: notice.message, message: notice.detail,
                action: notice.kind == .waiting ? nil : "Try Again"
            )
        case .archived:
            return CloudConnectionBanner(tone: .failure, title: "This Cloud workspace was archived", message: "Its machine and its conversation were deleted.")
        case .noAccess(let message):
            return CloudConnectionBanner(tone: .failure, title: "You cannot open this Cloud workspace", message: message, action: "Try Again")
        case .retrying(let message):
            return CloudConnectionBanner(tone: .caution, title: "Reconnecting…", message: message)
        }
    }
}
