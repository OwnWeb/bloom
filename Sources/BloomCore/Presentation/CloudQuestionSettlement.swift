import BloomProtocol
import Foundation

/// Which of a Cloud chat's open question rows have been answered, for a reader who only sees what
/// the machine publishes: the rows, and the list of questions still waiting.
///
/// **A question row that is not in the waiting list is not thereby answered.** That used to be
/// the whole rule, and it drew "Answered." over an AskUserQuestion that was still waiting on the
/// machine, with the agent blocked and the `permission_asks` row unresolved. The machine had
/// published the row before the question, so for the length of one event the row was a question
/// nobody was waiting on, and a settled row is never reopened. The machine sends them the other
/// way round now (see `WorkspaceRuntime.storeChanged`), and this is the reader's half, because a
/// machine running an older build still sends them in the old order.
///
/// So a row is answered on evidence, of which there are two kinds:
///
/// - **it was waiting and is not any more.** That is the live case, whoever answered it; and it
///   is remembered across history reads, so a reconnection that no longer lists a question this
///   reader saw waiting settles it too;
/// - **the transcript went on past it.** A tool result for the call it asked about means the call
///   ran or was refused, and a `result` means the turn ended, which a turn cannot do while it is
///   blocked on a question. This is what settles the questions in a history nobody watched live.
///
/// A row with neither stays open, which is what a question that has arrived ahead of its entry in
/// the list is. The worst an open row can do is offer an answer the machine refuses with "already
/// answered", which says so; a settled row over a waiting agent says nothing at all.
public struct CloudQuestionSettlement: Sendable, Hashable {
    /// A question row with nothing decided on it yet.
    public struct OpenAsk: Sendable, Hashable {
        public var requestID: String
        public var toolUseID: String
        public var seq: Int

        public init(requestID: String, toolUseID: String, seq: Int) {
            self.requestID = requestID
            self.toolUseID = toolUseID
            self.seq = seq
        }
    }

    /// Every request id this reader has seen in a waiting list.
    private var seenWaiting: Set<String> = []

    public init() {}

    /// The request ids among `asks` that have been answered. `waiting` is the chat's questions as
    /// the machine last published them, and `messages` its rows in `seq` order.
    public mutating func answered(
        _ asks: [OpenAsk], waiting: Set<String>, messages: [MessageRecord]
    ) -> Set<String> {
        seenWaiting.formUnion(waiting)
        var answered: Set<String> = []
        var unproven: [OpenAsk] = []
        for ask in asks where !waiting.contains(ask.requestID) {
            if seenWaiting.contains(ask.requestID) {
                answered.insert(ask.requestID)
            } else {
                unproven.append(ask)
            }
        }
        guard !unproven.isEmpty else { return answered }

        // One walk back from the newest row, which stops at the oldest question still to prove. An
        // unproven question is almost always the newest row there is, so the walk is a row or two.
        unproven.sort { $0.seq > $1.seq }
        var next = 0
        var turnEnded = false
        var resultsFor: Set<String> = []
        func decide(_ ask: OpenAsk) {
            if turnEnded || (!ask.toolUseID.isEmpty && resultsFor.contains(ask.toolUseID)) {
                answered.insert(ask.requestID)
            }
        }
        for message in messages.reversed() {
            while next < unproven.count, message.seq <= unproven[next].seq {
                decide(unproven[next])
                next += 1
            }
            if next == unproven.count { break }
            if message.kind == MessageKind.result.rawValue { turnEnded = true }
            if message.kind == MessageKind.toolResult.rawValue, let id = message.refID { resultsFor.insert(id) }
        }
        while next < unproven.count {
            decide(unproven[next])
            next += 1
        }
        return answered
    }
}
