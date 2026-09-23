import Foundation

/// A turn that was stopped before the CLI said it was over, and the `result` line said for it.
///
/// **The bug: a chat that queued everything for the rest of the launch.** The owner stopped a
/// turn that was still waiting on the model, and the `claude` child went away without printing
/// the `error_during_execution` result SIGTERM normally makes it print on its way out. The runner
/// took the cancelled branch of `finish`, which filed the session as `cancelled` and yielded
/// nothing at all, so the transcript never heard that the turn had ended. Its checkpoint stayed
/// open, and an open checkpoint on a chat that is not running is exactly what the queue reads as
/// "a turn is still being wrapped up": every message after that was queued, the drain refused to
/// move, Try Again called the refusing drain, and Stop had already been taken away because nothing
/// was running. Only quitting Bloom cleared it.
///
/// Every reader of a turn's ending already knows what a stopped turn's result looks like, because
/// the CLI prints one nearly every time: the footer draws "Stopped" for it, `TurnOutcome` stays
/// quiet about it, `SessionLifecycle` leaves the `cancelled` state alone, a Steer sends its message
/// on it and the queue stays paused behind it. So the runner says that same line when the CLI did
/// not, rather than inventing a second kind of ending for each of those readers to learn.
///
/// Here rather than in the runner because what counts as owing a result is a rule, and the test
/// target can check a rule without a process.
public enum UnreportedStop {
    /// Whether a stopped run still owes the transcript the line that closes its turn.
    ///
    /// - Parameter stoppedMidTurn: whether a turn was open at the moment the stop reached the
    ///   session. A stop that lands after the turn finished by itself closes nothing, and a second
    ///   result under a turn that already has one would draw a second footer.
    /// - Parameter reportedSince: whether the CLI printed its own result after the stop, which is
    ///   the ordinary case and needs nothing added.
    public static func owesResult(stoppedMidTurn: Bool, reportedSince: Bool) -> Bool {
        stoppedMidTurn && !reportedSince
    }

    /// The line the CLI prints for its own SIGTERM, with a key saying Bloom wrote it.
    ///
    /// The key is for whoever reads the database afterwards: without it a row the CLI never
    /// printed would be indistinguishable from one it did. No `origin`, deliberately, because a
    /// result naming one is a turn the CLI started for itself and is dropped as stray.
    public static func line(sessionID: String?) -> Data {
        var object: [String: JSONValue] = [
            "type": .string("result"),
            "subtype": .string("error_during_execution"),
            "is_error": .bool(true),
            "result": .string(""),
            "duration_ms": .integer(0),
            "num_turns": .integer(0),
            marker: .bool(true),
        ]
        if let sessionID, !sessionID.isEmpty { object["session_id"] = .string(sessionID) }
        return Data(JSONValue.object(object).compactJSON.utf8)
    }

    /// The event the runner ingests, decoded from `line` so the stored row and the event handed
    /// to the window cannot describe two different things.
    public static func event(sessionID: String?) -> AgentEvent {
        let raw = line(sessionID: sessionID)
        return AgentEvent.decode(line: String(decoding: raw, as: UTF8.self))
            ?? .result(AgentResult(isError: true, subtype: "error_during_execution", raw: raw))
    }

    public static let marker = "bloom_stopped_before_result"
}
