import Foundation

/// Whether a plan turn's last answer is a plan, or only a question back to the person.
///
/// OpenCode has no plan item, and its failed `question` tool tells the model to "ask the user in
/// your reply", so a plan turn can end on a question that must not become the chat's plan.
/// A reply is a question when it has no heading and every line of prose in it ends with `?`.
/// List items, code and lines ending with `:` are not prose: they hold options or introduce them.
/// A reply with no prose at all is a question when every list item in it is one.
/// The ceiling: a plan made of a bare list closed by "Shall I go ahead?" reads as a question, and
/// is dropped rather than a question being kept.
public enum OpenCodePlanReply {
    public static func isPlan(_ text: String) -> Bool {
        var inCode = false
        var prose: [String] = []
        var items: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inCode.toggle(); continue }
            if inCode || line.isEmpty { continue }
            if line.hasPrefix("#") { return true }
            if isListItem(line) { items.append(line); continue }
            if line.hasSuffix(":") { continue }
            prose.append(line)
        }
        let sentences = prose.isEmpty ? items : prose
        return !sentences.isEmpty && !sentences.allSatisfy { $0.hasSuffix("?") }
    }

    private static func isListItem(_ line: String) -> Bool {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("|") { return true }
        let digits = line.prefix { $0.isNumber }
        return !digits.isEmpty && line.dropFirst(digits.count).hasPrefix(". ")
    }
}
