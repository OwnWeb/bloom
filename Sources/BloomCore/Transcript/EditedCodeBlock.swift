import Foundation
import CryptoKit

/// A fence from an agent's answer, edited in the transcript and handed back as an attachment.
///
/// A file rather than the code pasted into the draft, for the reason a CI log is one: a fence worth
/// editing is usually long, and a draft holding forty lines of it is a draft nobody can write a
/// sentence around.
public enum EditedCodeBlock {
    /// The file the fence says it is, when it says: ```` ```swift title="Store.swift" ```` or
    /// ```` ```swift Sources/Store.swift ````, attached as `Store.swift` so the agent recognises
    /// its own file. Only the last path component, because the attachment folder is flat and a
    /// slash would quietly make another one. Otherwise the dated name below.
    public static func filename(
        info: String,
        language: Language,
        at date: Date = .now,
        timeZone: TimeZone = .current
    ) -> String {
        named(in: info) ?? filename(language: language, at: date, timeZone: timeZone)
    }

    /// Named like a pasted picture, `Edited 2026-10-09 at 07.59.04.swift`, so a folder of them sorts
    /// by when they were made and the chip says what the file is. The extension comes from the
    /// fence's language, so the agent and anything that opens the file read it as that language.
    public static func filename(
        language: Language,
        at date: Date = .now,
        timeZone: TimeZone = .current
    ) -> String {
        "Edited \(PastedAttachment.timestamp(date, in: timeZone)).\(fileExtension(for: language))"
    }

    static func named(in info: String) -> String? {
        let keyed = /(?:^|\s)(?:title|file|filename|path|name)=(?:"([^"]*)"|'([^']*)'|(\S+))/
        let candidate: Substring? = if let match = info.firstMatch(of: keyed) {
            match.1 ?? match.2 ?? match.3
        } else {
            // A bare word after the language is a name only when it looks like one, so
            // ```` ```js {1,3} ```` is not attached as `{1,3}`, nor an attribute nobody named as
            // the file as `highlight_name=x.sh`.
            info.split(whereSeparator: \.isWhitespace).dropFirst().first {
                $0.contains(".") && !$0.contains("=")
            }
        }
        guard let candidate else { return nil }

        // A colon is rewritten by the Finder and a backtick would close the code span the path
        // is written in, as `CheckFailureHandoff.logFilename` found first.
        var safe = (String(candidate) as NSString).lastPathComponent
        for bad in [":", "`"] { safe = safe.replacingOccurrences(of: bad, with: "-") }
        safe = safe.trimmingCharacters(in: .whitespaces)
        while safe.hasPrefix(".") { safe.removeFirst() }
        return safe.isEmpty ? nil : safe
    }

    /// Which block a draft belongs to: the conversation, the row, and the code itself, because a
    /// row can hold several fences and nothing else tells them apart. Hashed so the key stays
    /// short whatever the fence holds, and SHA-256 rather than `hashValue`, which changes on every
    /// launch and would orphan every draft a relaunch was meant to keep.
    public static func draftKey(session: String, entry: String, code: String) -> String {
        let digest = SHA256.hash(data: Data(code.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "\(session)/\(entry)/\(digest)"
    }

    /// The inverse of `Language.detect(path:)`, which is what the test holds it to.
    static func fileExtension(for language: Language) -> String {
        switch language {
        case .php: "php"
        case .swift: "swift"
        case .javascript: "js"
        case .typescript: "ts"
        case .python: "py"
        case .ruby: "rb"
        case .go: "go"
        case .rust: "rs"
        case .java: "java"
        case .kotlin: "kt"
        case .css: "css"
        case .html: "html"
        case .json: "json"
        case .yaml: "yaml"
        case .toml: "toml"
        case .markdown: "md"
        case .shell: "sh"
        case .sql: "sql"
        case .blade: "blade.php"
        case .vue: "vue"
        case .xml: "xml"
        case .plainText: "txt"
        }
    }
}
