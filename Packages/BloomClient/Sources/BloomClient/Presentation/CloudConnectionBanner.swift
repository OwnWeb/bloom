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
        /// Open runbloom.app, where limits, keys, GitHub and early access are settled.
        case runbloom
        /// Show the setup output, which is the only account of what a machine is doing before its
        /// first chat exists.
        case watchSetup
        /// Run the project's setup scripts again on the machine.
        case runSetupAgain

        public var title: String {
            switch self {
            case .wake: "Wake"
            case .retry: "Try Again"
            case .runbloom: "Open runbloom.app"
            case .watchSetup: "Watch Setup"
            case .runSetupAgain: "Run Setup Again"
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
        case .asleep:
            return CloudConnectionBanner(
                tone: .caution, title: "This Cloud workspace is asleep",
                message: "It went to sleep because nobody was using it. It wakes as soon as you do something in it.", actions: [.wake]
            )
        case .notReady(let message, _):
            return CloudConnectionBanner(tone: .progress, title: "Getting this Cloud workspace ready…", message: message, actions: [.watchSetup])
        case .limited(let notice):
            // A limit that clears by itself needs nobody; every other one is settled on runbloom.app,
            // by somebody who can raise it, so the way there is offered beside trying again.
            return CloudConnectionBanner(
                tone: notice.kind == .waiting ? .caution : .failure, title: notice.message, message: notice.detail,
                actions: notice.kind == .waiting ? [] : [.runbloom, .retry]
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
            return CloudConnectionBanner(tone: .caution, title: "Reconnecting…", message: message, actions: [.retry])
        }
    }

    /// What setup is doing, for a workspace whose machine has not finished starting or whose setup
    /// failed. Nil once setup has succeeded or where the project has no setup to run.
    ///
    /// - Parameters:
    ///   - isWatching: whether the setup output is already on screen, which is the one case where
    ///     offering to show it would be a button that does nothing.
    ///   - canRunSetup: whether this person's token carries the ability to run it again.
    public static func ofSetup(_ setup: SetupRecord?, isWatching: Bool, canRunSetup: Bool) -> CloudConnectionBanner? {
        guard let setup else { return nil }
        switch setup.state {
        case "pending":
            return CloudConnectionBanner(
                tone: .progress, title: "Setting up this Cloud workspace…",
                message: "It is cloning the repository and running the project's setup. This takes a few minutes the first time.",
                actions: isWatching ? [] : [.watchSetup]
            )
        case "running":
            let step = Self.stepNames[setup.step ?? ""] ?? setup.step
            return CloudConnectionBanner(
                tone: .progress, title: step.map { "Setting up this Cloud workspace: \($0)" } ?? "Setting up this Cloud workspace…",
                message: "It takes a few minutes the first time. You can watch what it is doing, and anything you send waits until it is done.",
                actions: isWatching ? [] : [.watchSetup]
            )
        case "failed":
            var actions: [Action] = isWatching ? [] : [.watchSetup]
            if canRunSetup { actions.append(.runSetupAgain) }
            return CloudConnectionBanner(
                tone: .failure, title: "Setting up this Cloud workspace failed",
                message: "The setup output says what went wrong. Fix it in the project's setup script, then run setup again, or archive this workspace and make another. The Setup tab keeps the whole of it.",
                actions: actions,
                dismissalKey: "setup-failed:\(setup.finishedAt?.timeIntervalSince1970.rounded() ?? 0)"
            )
        default:
            return nil
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

    private static let stepNames = [
        "clone": "cloning the repository", "prepare": "preparing the machine", "setup": "running the project's setup",
        "resume": "resuming", "services": "starting the project's services",
    ]
}
