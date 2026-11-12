import Foundation

/// The head of a sent message too long to draw whole.
///
/// A pasted API response or a base64 image is hundreds of kilobytes on one line, and laying it out
/// in a bubble froze the window on entering the chat. The bubble draws this head until the reader
/// asks for the rest. Blocks Bloom appended are drawn as chips, so they are kept whole and cost
/// nothing: cut, they would no longer be recognised.
public enum SentTurnPreview {
    public static let maxLines = 30
    public static let maxCharacters = 2_000
    public static let ellipsis = "…"

    /// The first lines or characters of `text` with an ellipsis, or nil when it is short enough to
    /// draw whole. Looks for Bloom's blocks only in a text already over the limits.
    public static func cut(_ text: String) -> String? {
        guard let end = limit(of: text, skipping: []) else { return nil }
        let blocks = SentTurn.blockRanges(in: text)
        guard !blocks.isEmpty else { return String(text[..<end]) + ellipsis }
        return limit(of: text, skipping: blocks).map { String(text[..<$0]) + ellipsis }
    }

    /// Where the head stops, or nil when the text ends first. Reads at most `maxCharacters`
    /// characters outside `blocks`, whatever the length of `text`.
    private static func limit(of text: String, skipping blocks: [Range<String.Index>]) -> String.Index? {
        var lines = 1
        var characters = 0
        var index = text.startIndex
        var pending = blocks[...]
        while index < text.endIndex {
            if let block = pending.first, block.lowerBound == index {
                index = block.upperBound
                pending.removeFirst()
                continue
            }
            let isNewline = text[index].isNewline
            let isLastCharacter = text.index(after: index) == text.endIndex
            if characters == maxCharacters || (isNewline && lines == maxLines && !isLastCharacter) {
                return index
            }
            if isNewline { lines += 1 }
            characters += 1
            index = text.index(after: index)
        }
        return nil
    }
}
