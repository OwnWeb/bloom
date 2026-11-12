import Foundation

/// The head of a sent message too long to draw whole.
///
/// A pasted API response or a base64 image is hundreds of kilobytes on one line, and laying it out
/// in a bubble froze the window on entering the chat. The bubble draws this head until the reader
/// asks for the rest.
public enum SentTurnPreview {
    public static let maxLines = 30
    public static let maxCharacters = 2_000
    public static let ellipsis = "…"

    /// The first lines or characters of `text` with an ellipsis, or nil when it is short enough to
    /// draw whole. Reads at most `maxCharacters` characters, whatever the length of `text`.
    public static func cut(_ text: String) -> String? {
        var lines = 1
        var characters = 0
        var index = text.startIndex
        while index < text.endIndex {
            let reachedLines = text[index].isNewline && lines == maxLines
            if characters == maxCharacters || reachedLines {
                return String(text[..<index]) + ellipsis
            }
            if text[index].isNewline { lines += 1 }
            characters += 1
            index = text.index(after: index)
        }
        return nil
    }
}
