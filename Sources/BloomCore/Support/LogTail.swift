import Foundation

/// The last few lines of something that is still being written to.
///
/// A setup script is `composer install` and `bun install` and a database being created: thousands
/// of lines, arriving continuously. The transcript shows the end of that rather than the whole of
/// it, because the transcript is a reading surface and the full log already has a tab of its own.
///
/// Taken from the END, which is the difference between this and `TextCap`. A cap from the front is
/// right for a tool result, which is a finished thing whose first lines say what it is; a log that
/// is still running is only interesting at the bottom, where the line that is about to change is.
///
/// Written as one backwards walk over the string rather than `split(separator:)` and a suffix: the
/// log is capped at 200,000 characters and splitting it allocates every line of it to keep four.
public enum LogTail {
    /// The last `lines` lines, with trailing blank lines ignored so a log that ends in a newline
    /// does not spend one of them on nothing.
    public static func last(_ text: String, lines: Int) -> String {
        guard lines > 0 else { return "" }

        var end = text.endIndex
        while end > text.startIndex {
            let previous = text.index(before: end)
            guard text[previous].isNewline else { break }
            end = previous
        }
        guard end > text.startIndex else { return "" }

        var start = end
        var seen = 0
        while start > text.startIndex {
            let previous = text.index(before: start)
            if text[previous].isNewline {
                seen += 1
                if seen == lines { break }
            }
            start = previous
        }

        return String(text[start..<end])
    }

    /// Whether there is anything in this log a reader would see.
    ///
    /// **A chevron that opens onto nothing is worse than no chevron**, and "the log is not an empty
    /// string" is not the same question as "there is something to read". A setup whose output was
    /// five blank lines drew a disclosure, said "5 lines of output" under the row, and opened onto
    /// nothing at all, because the tail drops trailing newlines and there was nothing else in it.
    /// Escape sequences do the same thing one step further on: a clear-screen is four bytes, is not
    /// whitespace, and draws as nothing.
    ///
    /// So this asks the only question the row cares about: is there a character in here that would
    /// leave a mark. CSI sequences are walked over rather than counted, which covers the colours
    /// and cursor moves a script's output carries; anything else that is not whitespace and not a
    /// control character is something to show.
    public static func hasSomethingToShow(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            // ESC [ … final, which is every colour, cursor move and clear this meets.
            if scalar == "\u{1b}" {
                index += 1
                if index < scalars.count, scalars[index] == "[" { index += 1 }
                while index < scalars.count, !("\u{40}"..."\u{7e}").contains(scalars[index]) { index += 1 }
                index += 1
                continue
            }
            if !CharacterSet.whitespacesAndNewlines.contains(scalar), !CharacterSet.controlCharacters.contains(scalar) {
                return true
            }
            index += 1
        }
        return false
    }

    /// The last line with anything on it, which is what a one line status shows while a script is
    /// running. Empty when the log is empty or is nothing but whitespace.
    public static func lastLine(_ text: String) -> String {
        let tail = last(text, lines: 1)
        return tail.trimmingCharacters(in: .whitespaces)
    }

    /// How many lines the log holds, counted rather than split, so a status line can say how big
    /// the thing behind the disclosure is.
    /// Counted over UTF-8 bytes rather than over `Character`s, and that is a measured decision
    /// rather than a stylistic one.
    ///
    /// This is asked from a view body: `WorkspaceEventRow` reads it to decide how many lines the
    /// running tail is drawn at and whether the "Show more of the log" link is worth drawing, so
    /// it is answered on every pass of the view graph, which during a window resize is once a
    /// frame or more. Over a `String` the walk is a grapheme-breaking walk: every step consults
    /// the Unicode tables to find where the next `Character` ends, and `isNewline` then compares
    /// scalars. Sampled on a real window during a resize, this one function was 12.8% of the main
    /// thread, and the `WorkspaceEventRow` body that calls it was 17.2%.
    ///
    /// A line separator in a log is `\n`, `\r` or `\r\n`, all of which are single bytes in UTF-8
    /// and none of which can appear inside the encoding of any other scalar, so a byte scan
    /// answers the same question without decoding anything. The `\r\n` pair is counted once, which
    /// is what the grapheme walk did: in Swift a CRLF is one `Character`.
    ///
    /// The exotic separators `Character.isNewline` also accepts (vertical tab, form feed, NEL,
    /// U+2028, U+2029) are deliberately not counted. A setup script's output does not contain
    /// them, and `SetupDiagnosis.split`, which decides what a LINE of a log actually is, has never
    /// recognised them either: counting them here would have this disagree with what is drawn.
    /// Walked over the string's own UTF-8 view rather than over `Array(text.utf8)`, which is the
    /// second half of the same measurement. The byte scan was the cheap part; the copy in front of
    /// it was not. A log of two hundred thousand characters allocates and fills two hundred
    /// thousand bytes before a single one of them is looked at, and this is asked from a view body.
    ///
    /// One forward pass, because a `String.UTF8View` walks forwards cheaply and backwards through
    /// its index arithmetic. The trailing newlines the old walk trimmed first are dropped at the
    /// end instead: separators are counted as they are seen, and the run of them that no content
    /// follows is taken off the total. That is the same answer, arrived at without knowing where
    /// the end of the content is until the end is reached.
    public static func lineCount(_ text: String) -> Int {
        let bytes = text.utf8
        let end = bytes.endIndex

        var total = 0
        /// Separators seen since the last byte that was not one, which at the end of the walk is
        /// exactly the trailing run the old code trimmed before counting.
        var sinceContent = 0
        var sawContent = false

        var index = bytes.startIndex
        while index < end {
            let byte = bytes[index]
            index = bytes.index(after: index)
            if byte == 0x0D {
                total += 1
                sinceContent += 1
                // A CRLF is one separator, and one `Character`.
                if index < end, bytes[index] == 0x0A { index = bytes.index(after: index) }
            } else if byte == 0x0A {
                total += 1
                sinceContent += 1
            } else {
                sawContent = true
                sinceContent = 0
            }
        }

        guard sawContent else { return 0 }
        return 1 + total - sinceContent
    }
}
