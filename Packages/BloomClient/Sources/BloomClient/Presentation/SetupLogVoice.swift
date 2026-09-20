import Foundation

/// Which lines of a setup log the machine wrote and which the project's own scripts did.
///
/// **Every line Bloom itself writes into a machine's setup log begins `[bloom] `, and everything
/// else is the project's output.** That one marker is the whole of the wire contract, and it is
/// worth more than a field per sentence: it makes step headings, notes and outcomes tellable from
/// `composer install`'s stdout without the machine having to say which is which each time.
///
/// **The marker picks the ink and then goes.** A transcript row reading "[bloom] Cloning the
/// repository." puts a machine-readable prefix in front of a sentence written for a person. So it
/// is stripped wherever a line is shown as a sentence; what it buys is knowing that this line may
/// be shown that way at all, where a script's stdout may not.
///
/// Here rather than beside the row, because the web client reads the same log and two clients
/// working out what the marker means separately is how one of them ends up printing it.
public enum SetupLogVoice {
    /// What the machine puts in front of its own lines.
    public static let marker = "[bloom] "

    /// Whether this line is the machine's own words rather than a script's output.
    public static func isBloom(_ line: String) -> Bool {
        line.hasPrefix(marker)
    }

    /// The line as a person should read it: the marker off, and a script's output unchanged.
    public static func spoken(_ line: String) -> String {
        guard isBloom(line) else { return line }
        return String(line.dropFirst(marker.count))
    }

    /// The newest thing the machine said about this run, for the sentence under the row.
    ///
    /// **Its own words rather than ours, which is the point.** The machine writes a sentence when
    /// a step has printed nothing for five minutes, and another when a run is starting again
    /// because the machine stopped mid-setup. Both are better than anything this side could invent
    /// about a machine it cannot see, and surfacing them costs one rule rather than one field each.
    ///
    /// - Parameter heading: the step's own title, which the row is already showing as its one
    ///   line. A step heading is a `[bloom]` line too, so without this the note under the row
    ///   would be the line above it, said twice. Compared with the punctuation and the case taken
    ///   off, because a heading is a sentence and the row's line is a fragment of one.
    ///
    /// Nil where the machine has said nothing but its headings, which is most of a healthy run.
    public static func newestNote(in log: String, excluding heading: String? = nil) -> String? {
        let skip = heading.map(plain)
        for line in log.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            let text = String(line)
            guard isBloom(text) else { continue }
            let said = spoken(text).trimmingCharacters(in: .whitespaces)
            guard !said.isEmpty else { continue }
            if let skip, plain(said) == skip { return nil }
            return said
        }
        return nil
    }

    /// How many lines of this log the **project** printed, which is what "45 lines of output"
    /// should have been counting.
    ///
    /// **Bloom's own narration is not output.** The machine writes a heading per step, a note when
    /// a run starts again, a sentence when something goes quiet and one for the outcome, and a row
    /// counting those told a reader their setup script had printed a dozen lines it never wrote.
    /// The web client found the same counter doing the same thing.
    ///
    /// Blank lines are not counted either, for `LogTail.hasSomethingToShow`'s reason: a count is a
    /// promise about what opening the disclosure will show, and trailing newlines show nothing.
    public static func outputLines(in log: String) -> Int {
        log.split(separator: "\n").reduce(into: 0) { count, line in
            let text = String(line)
            guard !isBloom(text), !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            count += 1
        }
    }

    /// A sentence with the things two spellings of it would differ by taken off: the case, the
    /// surrounding space, and a full stop at the end.
    private static func plain(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        while trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed
    }
}
