import Foundation

/// Whether a Cloud workspace's machine has a reason to stay awake, and until when.
///
/// **An open connection is not a reason.** A machine stays up while anything is connected to it,
/// so a Mac left open on a workspace over a weekend would bill for the weekend. Bloom Runner holds
/// the machine awake with a task of its own instead, and only for these:
///
/// - setup or resume is running;
/// - a turn is running, and one waiting on a question counts for at most the presence lease after
///   the question was asked, because an unanswered question at six in the evening must not keep a
///   machine up until morning (the question survives the pause, and answering wakes it);
/// - a run script somebody started is running;
/// - the human presence lease: fifteen minutes after the last human input from anybody.
///
/// The lease is cut short in one case, because it costs a counter the server already has: when the
/// last event stream closes, the lease ends two minutes later unless somebody does something in
/// between. A client left open and idle is not detected; that would need every client to report
/// its own visibility, which is more machinery than the minutes it would save.
///
/// Pure, so every rule above is a test rather than a hope. See docs/REMOTE-WORKSPACES.md, "Awake,
/// asleep, and what it costs".
public struct RemoteAwakePolicy: Sendable, Hashable {
    public static let presenceLease: TimeInterval = 15 * 60
    public static let afterLastStreamCloses: TimeInterval = 2 * 60

    public enum Reason: String, Sendable, Hashable, CaseIterable {
        case setup
        case turn
        case script
        case humanInput = "human_input"
    }

    public struct Situation: Sendable, Hashable {
        public var setupRunning = false
        public var turnsRunning = 0
        /// When the oldest question still waiting was asked, while a turn is waiting on one.
        public var questionWaitingSince: Date?
        public var scriptsRunning = 0
        public var lastHumanInputAt: Date?
        public var openStreams = 0
        /// When the last stream closed, leaving none open.
        public var lastStreamClosedAt: Date?

        public init(
            setupRunning: Bool = false, turnsRunning: Int = 0, questionWaitingSince: Date? = nil, scriptsRunning: Int = 0,
            lastHumanInputAt: Date? = nil, openStreams: Int = 0, lastStreamClosedAt: Date? = nil
        ) {
            self.setupRunning = setupRunning
            self.turnsRunning = turnsRunning
            self.questionWaitingSince = questionWaitingSince
            self.scriptsRunning = scriptsRunning
            self.lastHumanInputAt = lastHumanInputAt
            self.openStreams = openStreams
            self.lastStreamClosedAt = lastStreamClosedAt
        }
    }

    public struct Decision: Sendable, Hashable {
        /// Why the machine stays awake, empty when it may sleep. The first is what a usage report
        /// names as the reason it woke.
        public var reasons: [Reason]
        /// When the presence lease runs out, if it is what holds or could hold the machine.
        public var leaseUntil: Date?
        /// The next moment the answer can change without anything happening, which is when to ask
        /// again. Nil when only an event can change it.
        public var reconsiderAt: Date?

        public var holds: Bool { !reasons.isEmpty }
    }

    public static func decide(_ situation: Situation, now: Date) -> Decision {
        var reasons: [Reason] = []
        var reconsiderAt: Date?
        func later(_ date: Date) {
            guard date > now else { return }
            reconsiderAt = min(reconsiderAt ?? date, date)
        }

        if situation.setupRunning { reasons.append(.setup) }
        if situation.turnsRunning > 0 {
            if let asked = situation.questionWaitingSince {
                let limit = asked.addingTimeInterval(presenceLease)
                if now < limit {
                    reasons.append(.turn)
                    later(limit)
                }
            } else {
                reasons.append(.turn)
            }
        }
        if situation.scriptsRunning > 0 { reasons.append(.script) }

        let lease = leaseEnd(situation)
        if let lease, now < lease {
            reasons.append(.humanInput)
            later(lease)
        }
        return Decision(reasons: reasons, leaseUntil: lease, reconsiderAt: reconsiderAt)
    }

    /// When the presence lease ends: fifteen minutes after the last input, or two minutes after
    /// the last stream closed when that is sooner and nobody did anything since it closed.
    static func leaseEnd(_ situation: Situation) -> Date? {
        guard let input = situation.lastHumanInputAt else { return nil }
        let full = input.addingTimeInterval(presenceLease)
        guard situation.openStreams == 0, let closed = situation.lastStreamClosedAt, input <= closed else { return full }
        return min(full, closed.addingTimeInterval(afterLastStreamCloses))
    }
}
