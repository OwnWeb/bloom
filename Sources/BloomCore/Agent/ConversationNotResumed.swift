import Foundation

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
