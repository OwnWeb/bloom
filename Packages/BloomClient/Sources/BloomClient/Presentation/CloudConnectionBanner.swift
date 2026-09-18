import BloomProtocol
import Foundation

/// The line over an open Cloud workspace that says where it is, and what to do about it.
///
/// **Every state a first Cloud workspace passes through has a way forward here, or says plainly
/// that it needs nothing.** A bare state ("blocked", "not ready", "failed") leaves the reader with
/// a sentence and no button, which is what the app did at each of these before they were written
/// down in one place and tested.
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

    /// The ways forward a banner offers, in the order they are drawn. Named rather than spelled as
    /// strings, so the window cannot offer a button that does nothing and a test can say which
    /// state offers what.
    public enum Action: Sendable, Hashable {
        /// Wake a sleeping machine now, rather than on the next thing typed.
        case wake
        /// Try the connection again, after a network failure or a refusal that may have lifted.
        case retry
        /// The same act as `retry` where Bloom is **already** asking by itself, which is a
        /// different sentence: nothing was abandoned, so there is nothing to try again. What the
        /// press buys is skipping the wait before the next automatic attempt, which is at most
        /// half a minute. See `WorkspaceConnection.resume(announcing:)`.
        case askNow
        /// Open runbloom.app, where limits, keys, GitHub and early access are settled.
        case runbloom
        /// Show the setup output, which is the only account of what a machine is doing before its
        /// first chat exists.
        /// Run the project's setup scripts again on the machine.

        public var title: String {
            switch self {
            case .wake: "Wake"
            case .retry: "Try Again"
            case .askNow: "Ask now"
            case .runbloom: "Open runbloom.app"
            }
        }
    }

    public var tone: Tone
    public var title: String
    public var message: String?
    public var actions: [Action]
    /// What a dismissal is remembered against, or nil for a banner that cannot be dismissed.
    ///
    /// **A banner that is a state can be put away; one that is a blocker cannot.** Waking,
    /// reconnecting and setting up all end by themselves, so a close button on them would only be
    /// a way to hide something about to go anyway. Archived and no access are the opposite: the
    /// workspace does nothing until they are dealt with, and a hidden one reads as an app that
    /// silently stopped working. What is left is a setup that failed, which is a state somebody
    /// can live with while they fix the script, and it is the one this exists for.
    ///
    /// The key carries when the state was reached, so the NEXT failure is a different banner and
    /// comes back rather than staying hidden behind a dismissal of the last one.
    public var dismissalKey: String?

    public init(tone: Tone, title: String, message: String? = nil, actions: [Action] = [], dismissalKey: String? = nil) {
        self.tone = tone
        self.title = title
        self.message = message
        self.actions = actions
        self.dismissalKey = dismissalKey
    }

    public static func of(_ phase: WorkspaceConnection.Phase) -> CloudConnectionBanner? {
        switch phase {
        case .closed, .live, .connecting(waking: false):
            return nil
        case .connecting(waking: true):
            return CloudConnectionBanner(tone: .progress, title: "Waking this Cloud workspace…", message: "It was asleep. This usually takes a few seconds.")
        case .notWaking:
            // **The sentence above has an end now.** It said "this usually takes a few seconds"
            // for as long as the window was open, over a machine that had been asked and had not
            // come back, which is the same shape as a spinner that never stops. What wakes a
            // machine is the request the connection is already making and repeating, so this says
            // what is true, offers the two things worth doing, and keeps trying underneath.
            return CloudConnectionBanner(
                tone: .caution, title: "This Cloud workspace has not woken",
                // **"Nothing here needs doing" is the sentence somebody staring at this could not
                // get anywhere**, and it is what makes the button modest rather than obligatory.
                // "every half minute" is the backoff's own ceiling, where "keeps asking" gestured
                // at the fact and answered neither how often nor whether to wait. And runbloom.app
                // is a thing to do when it is worth doing rather than a fact about how Bloom is
                // put together: the old sentence said where the answer lives, which is not an
                // answer to "is this coming back".
                message: "It was asleep and has not answered. Bloom is still asking, every half minute. Nothing here needs doing. If it never comes back, runbloom.app says what happened to its machine.",
                actions: [.askNow, .runbloom]
            )
        case .asleep:
            return CloudConnectionBanner(
                tone: .caution, title: "This Cloud workspace is asleep",
                message: "It went to sleep because nobody was using it. It wakes as soon as you do something in it.", actions: [.wake]
            )
        case .notReady(let message, _):
            // No button: what it is doing is the setup row at the head of the conversation, which
            // is already on screen behind this banner.
            //
            // **The centre's words, because this is the centre's state.** It said "Getting this
            // Cloud workspace ready…" over a pane saying "Setting up your workspace", and two
            // names for one state is what the owner spotted from across the room. The banner keeps
            // the states only it can report; where it shares one, it shares the words.
            //
            // **And this banner says what it does about it, because the refusal no longer will.**
            // runbloom.app's sentence used to end "and this will reconnect automatically once it
            // is", which was true of every reader while every reader was a client that retries and
            // became a promise nobody was keeping the moment a web page read it. So the refusal
            // states the fact and each surface adds its own behaviour. This one keeps asking.
            return CloudConnectionBanner(
                tone: .progress, title: CloudOpeningNotice.title,
                message: message + " Bloom opens it as soon as it is."
            )
        case .limited(let notice):
            // A limit that clears by itself needs nobody; every other one is settled on runbloom.app,
            // by somebody who can raise it, so the way there is offered beside trying again.
            return CloudConnectionBanner(
                tone: notice.kind == .waiting ? .caution : .failure, title: notice.message, message: notice.detail,
                actions: notice.kind == .waiting ? [] : [.runbloom, .retry]
            )
        case .unavailable(let message):
            // runbloom.app's own sentence as the heading, the way a limit's is: it knows whether
            // the machine failed to build or is being deleted, and a heading of ours above it would
            // be the second line saying the same thing. No Try Again, because the refusal behind
            // this carried no retry hint, which is runbloom.app saying that asking again answers
            // the same. See `WorkspaceConnection.Phase.unavailable`.
            return CloudConnectionBanner(
                tone: .failure, title: message,
                message: "This Cloud workspace cannot be opened. runbloom.app has the rest of the story.",
                actions: [.runbloom]
            )
        case .archived:
            return CloudConnectionBanner(tone: .failure, title: "This Cloud workspace was archived", message: "It was deleted, with its conversation.")
        case .noAccess(let message):
            return CloudConnectionBanner(
                tone: .failure, title: "You cannot open this Cloud workspace", message: message, actions: [.runbloom, .retry]
            )
        case .retrying(let message):
            // A dropped network, a machine that stopped answering, a server restart. It retries by
            // itself with a backoff, and the button is for somebody who does not want to wait.
            // Asking rather than trying again, for `askNow`'s reason: the connection is already
            // reconnecting on a backoff, so nothing was given up.
            return CloudConnectionBanner(tone: .caution, title: "Reconnecting…", message: message, actions: [.askNow])
        }
    }

    /// What the machine's last update attempt is worth saying, or nil when there is nothing to
    /// say. The sentence is runbloom.app's own; what is decided here is how loudly it is drawn and
    /// whether it can be put away.
    ///
    /// A rollback in progress cannot be dismissed, because it ends by itself and is replaced by its
    /// outcome. The two outcomes can, on the same rule as a failed setup: they do not end by
    /// themselves and they do not stop the workspace working.
    public static func ofRunner(_ notice: CloudRunnerNotice?) -> CloudConnectionBanner? {
        guard let notice, !notice.message.isEmpty else { return nil }
        if notice.isUnderway {
            return CloudConnectionBanner(tone: .progress, title: "Putting this Cloud workspace back…", message: notice.message)
        }
        let isFailure = notice.kind == CloudRunnerNotice.failed
        return CloudConnectionBanner(
            tone: isFailure ? .failure : .caution,
            title: Self.runnerTitle(for: notice.kind),
            message: notice.message,
            dismissalKey: "runner:\(notice.kind):\(notice.at?.timeIntervalSince1970.rounded() ?? 0)"
        )
    }

    /// The heading over runbloom.app's own sentence. A kind this version does not know gets the
    /// plainest heading there is, because its sentence says the rest.
    private static func runnerTitle(for kind: String) -> String {
        switch kind {
        case CloudRunnerNotice.failed: "This Cloud workspace could not be updated"
        case CloudRunnerNotice.rolledBack: "This Cloud workspace was put back on an older version"
        case CloudRunnerNotice.interrupted: "This Cloud workspace's update was interrupted"
        default: "Something happened while this Cloud workspace was being updated"
        }
    }

    /// What a setup step is called in a sentence, which is `CloudSetupStep`'s one table rather
    /// than a second copy of it. Kept as a name here because the transcript row and this banner
    /// both ask for it by this name.
    public static func stepName(_ step: String?) -> String? { CloudSetupStep.sentence(step) }
}
