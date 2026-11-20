import Foundation

/// Whether a plan turn's last answer is a plan, or only a question back to the person.
///
/// OpenCode has no plan item, and its failed `question` tool tells the model to "ask the user in
/// your reply", so a plan turn can end on a question that must not become the chat's plan.
/// A reply is a plan as soon as it states something: a heading, a line of prose that does not end
/// with `?`, or a list item that does not end with `?` and is not an option offered by a question
/// just before it. Lines ending with `:` only introduce what follows, and code says nothing.
/// So "Here is the plan:" then steps then "Shall I proceed?" is a plan, and "Which one?" then
/// options is not.
public enum OpenCodePlanReply {
    public static func isPlan(_ text: String) -> Bool {
        var inCode = false
        var introducedByQuestion = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inCode.toggle(); continue }
            if inCode || line.isEmpty { continue }
            if line.hasPrefix("#") { return true }
            let asks = line.hasSuffix("?")
            if isListItem(line) {
                if !asks, !introducedByQuestion { return true }
                continue
            }
            // An introduction keeps the question in force: "Which one?" then "Options:" then a list.
            if line.hasSuffix(":") { continue }
            if !asks { return true }
            introducedByQuestion = true
        }
        return false
    }

    private static func isListItem(_ line: String) -> Bool {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("|") { return true }
        let digits = line.prefix { $0.isNumber }
        return !digits.isEmpty && line.dropFirst(digits.count).hasPrefix(". ")
    }
}
