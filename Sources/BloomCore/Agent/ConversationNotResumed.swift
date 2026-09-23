import Foundation

/// A `--resume` whose conversation is not on this machine, and the note left when the chat starts
/// a new one in its place.
///
/// **What the failure looks like, measured rather than assumed.** claude 2.1.280 handed a made-up
/// id prints one line on stdout and nothing before it: a `result` with `subtype`
/// `error_during_execution`, `is_error` true, `num_turns` 0, the id it was asked for as
/// `session_id`, and `errors` holding "No conversation found with session ID: <id>". The same
/// sentence goes to stderr and the exit status is 1. No `system/init` and no request: it fails
/// before it reaches the model, so starting again costs nothing that was spent.
///
/// **Why a Cloud machine meets it.** The conversation lives in the agent's own
/// `~/.claude/projects`, on the machine's disk, and the row naming it lives in Bloom's database. A
/// replaced machine, a fresh Sprite, carries the row and not the file, so every turn in that chat
/// resumed an id that was no longer there, failed before it began, and paused the queue behind
/// it. The chat never answered again.
///
/// The exact sentence is matched and nothing looser, because the way out forgets the agent's own
/// memory of the conversation, and that is a price only this failure is allowed to charge. A turn
/// that failed for any other reason keeps its id and resumes as before.
public enum ConversationNotResumed {
    static let phrase = "No conversation found with session ID"

    /// Whether a result is the CLI saying the conversation it was asked to resume is not there.
    public static func matches(_ result: AgentResult) -> Bool {
        guard result.isError,
              let json = try? JSONDecoder().decode(JSONValue.self, from: result.raw) else { return false }
        let errors = json["errors"]?.arrayValue?.compactMap(\.stringValue) ?? []
        return errors.contains { $0.contains(phrase) }
    }

    /// The same, for a CLI that says it on stderr and exits without a result, which reaches the
    /// transcript as an `.error` whose message carries the stderr.
    public static func matches(_ text: String) -> Bool {
        text.contains(phrase)
    }

    /// What the note says. One sentence that is true on a Mac, where the next message starts the
    /// new conversation, and on a Cloud machine, where the same turn is sent again at once.
    public static let sentence = "The earlier conversation could not be found on this machine, "
        + "so the agent starts a new one here without what was said above."

    static let subtype = "conversation_not_resumed"

    /// The stored `.notice` row.
    public static let note: Data = {
        let object: [String: String] = ["type": "bloom_note", "subtype": subtype, "message": sentence]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data(#"{"subtype":"conversation_not_resumed","type":"bloom_note"}"#.utf8)
    }()

    /// The note's sentence, or nil when a `.notice` row is something else, such as a rate limit.
    public static func sentence(fromNote payload: Data) -> String? {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: payload),
              json["subtype"]?.stringValue == subtype else { return nil }
        let message = json["message"]?.stringValue ?? ""
        return message.isEmpty ? sentence : message
    }
}
