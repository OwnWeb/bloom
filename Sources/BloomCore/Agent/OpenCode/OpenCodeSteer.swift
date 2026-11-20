import Foundation

/// What `_session/steering` answered. See "Steering" in `docs/OPENCODE.md`.
public enum OpenCodeSteerOutcome: Sendable, Hashable {
    /// Taken into the running turn. It is read once the step that is running has finished.
    case injected
    /// No turn was running, so nothing was stored and the words want a `session/prompt`.
    case promptRequired

    /// Nil for any other answer, which is not evidence either way about whether the words landed.
    static func decode(_ result: JSONValue) -> OpenCodeSteerOutcome? {
        switch result["outcome"]?.stringValue {
        case "injected": .injected
        case "promptRequired": .promptRequired
        default: nil
        }
    }
}

/// Whether the words a steer put into the turn have been read yet.
///
/// **`injected` is not "read".** OpenCode stores the words and reads them when the step that is
/// running ends. A turn stopped before then ends `cancelled` without them, and they stay in the
/// session to be read with the next prompt as if they had been sent with it (measured on 2.3.2).
/// Nothing on the wire says a steer was read, so the evidence is the reply to it: the model's
/// next message, which carries a `messageId` no chunk had before the steer.
///
/// **The message being streamed when the steer goes is not the reply**, and it may not have shown
/// an id yet: a turn whose first step is still thinking before its first chunk. So a steer sent
/// before the turn has shown anything takes the first id that follows as that step's own, and
/// waits for the one after it. A tool call settles the question the other way: a step that called
/// a tool without saying anything first has no text of its own to come, so the next id is the
/// reply. Tool calls carry no id themselves, so a reply that is only a tool call is not seen here
/// until it says something.
struct OpenCodeSteerReading: Sendable {
    private var seen: Set<String> = []
    private var calledATool = false
    private var awaitingReply: Set<String>?
    /// The steer went before the turn showed anything, so the next id is still the step's own.
    private var stepUnnamed = false
    /// Steers sent and not yet answered by the server, which may still turn out to be taken.
    private var onWire = 0
    /// A steer since the last reply was taken, so the words are in the session for certain.
    private var taken = false

    /// Some steered words have not been answered yet.
    var isUnread: Bool { awaitingReply != nil }

    /// A steer is still waiting for the server's answer, which alone says whether its words went.
    var isOnWire: Bool { onWire > 0 }

    mutating func observe(_ update: ACPSessionUpdate) {
        switch update.kind {
        case .text, .thought: observe(message: update.raw["messageId"]?.stringValue ?? "")
        case .toolCall:
            calledATool = true
            stepUnnamed = false
        default: return
        }
    }

    /// The thought of message `m` is `m:reasoning:0`, so both count as `m`.
    private mutating func observe(message raw: String) {
        guard !raw.isEmpty else { return }
        let message = String(raw.prefix { $0 != ":" })
        seen.insert(message)
        guard let before = awaitingReply, !before.contains(message) else { return }
        if stepUnnamed {
            awaitingReply?.insert(message)
            stepUnnamed = false
            return
        }
        taken = false
        // A steer still on the wire was sent after this reply began, so it waits for the next one.
        awaitingReply = onWire > 0 ? seen : nil
    }

    /// Called before the steer is sent. A reply that begins while it is on the wire does not count
    /// for its words: which of the two came first is unknown, and the wrong guess the other way
    /// would hide a notice the owner needs, while this one only shows a notice that was not.
    mutating func steered() {
        onWire += 1
        guard awaitingReply == nil else { return }
        awaitingReply = seen
        stepUnnamed = seen.isEmpty && !calledATool
    }

    /// The server answered a steer. Words nobody can show were taken stop being waited for once
    /// no steer is left on the wire.
    mutating func settled(taken wasTaken: Bool) {
        onWire = max(0, onWire - 1)
        if wasTaken { taken = true }
        guard onWire == 0, !taken else { return }
        awaitingReply = nil
        stepUnnamed = false
    }

    /// A new turn, or a finished one: nothing is pending any more.
    mutating func reset() {
        let wire = onWire
        self = OpenCodeSteerReading()
        onWire = wire
    }
}

/// The transcript's word for steered words a Stop left unread, which OpenCode sends with the next
/// message without a sign of it on screen.
public enum OpenCodeSteerNote {
    public static let sentence = "The turn was stopped before OpenCode read your last message, "
        + "so it goes to the agent with your next message."

    static let subtype = "opencode_steer_unread"

    /// The stored `.notice` row.
    public static let note: Data = {
        let object: [String: String] = ["type": "bloom_note", "subtype": subtype, "message": sentence]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data(#"{"subtype":"opencode_steer_unread","type":"bloom_note"}"#.utf8)
    }()

    /// The note's sentence, or nil when a `.notice` row is something else.
    public static func sentence(fromNote payload: Data) -> String? {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: payload),
              json["subtype"]?.stringValue == subtype else { return nil }
        let message = json["message"]?.stringValue ?? ""
        return message.isEmpty ? sentence : message
    }
}
