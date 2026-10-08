import Foundation

/// A composer draft that starts with `!`: a shell command run in the worktree rather than a message,
/// whose output goes to the agent as the next message once it has finished.
///
/// This is Claude Code's shell mode, done by Bloom. stream-json has no such mode, and Codex and Grok
/// have nothing like it either, so the output reaches the agent as an ordinary user message and every
/// agent gets it the same way. The agent answers it, which is the point: `! npm test` gets an
/// explanation of the failures without a second prompt.
public enum ShellCommand {
    /// Whether the composer is in shell mode, which it is from the moment the `!` is typed and
    /// before there is a command after it, as in Claude Code. The `!` has to be the first
    /// character, so a message that merely contains one further in is never run.
    public static func isShellMode(_ draft: String) -> Bool {
        draft.hasPrefix("!")
    }

    /// What the draft becomes when a `!` is typed into an empty composer: the `!` and a space, so
    /// the command is typed where Claude Code would put it. Nil for every other edit, including a
    /// paste that starts with `!` and a backspace over the space, which would otherwise come back.
    public static func autoSpaced(from old: String, to new: String) -> String? {
        old.isEmpty && new == "!" ? "! " : nil
    }

    /// The command a draft asks to run, or nil when the draft is a message. A lone `!` is nil:
    /// there is nothing to run.
    public static func command(in draft: String) -> String? {
        guard isShellMode(draft) else { return nil }
        let command = draft.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }

    /// A command running from a chat's composer, and what it has printed so far.
    public struct Run: Sendable, Equatable {
        public var command: String
        public var output = Output()

        public init(command: String) {
            self.command = command
        }
    }

    /// What a command printed, kept from both ends as it arrives.
    ///
    /// Both ends for the reason `CheckFailureHandoff.excerpt` gives: the tail is where a failure
    /// usually is, and a build that failed on its first file says so at the top. Kept as it arrives
    /// rather than cut at the end, because the whole output of `yes` or a chatty build is not
    /// something to hold in memory only to throw most of it away.
    public struct Output: Sendable, Equatable {
        static let headLines = CheckFailureHandoff.headLines
        static let tailLines = CheckFailureHandoff.tailLines
        /// One line of minified output can be a megabyte, and the line budget cannot see that.
        static let maxLineCharacters = 2_000
        static let maxCharacters = CheckFailureHandoff.maxCharacters

        public private(set) var head: [String] = []
        public private(set) var tail: [String] = []
        public private(set) var droppedLines = 0

        public init() {}

        public var isEmpty: Bool { head.isEmpty }

        public mutating func append(_ raw: String) {
            let line = Self.clean(raw)
            guard head.count == Self.headLines else {
                head.append(line)
                return
            }
            tail.append(line)
            if tail.count > Self.tailLines {
                tail.removeFirst()
                droppedLines += 1
            }
        }

        /// The last lines printed, for watching the command run.
        public func recent(_ count: Int) -> [String] {
            Array((head + tail).suffix(count))
        }

        /// What the agent is shown. The cut admits it is a cut, so the agent does not reason about
        /// a run it has only seen part of as if it had seen all of it.
        ///
        /// The character cap keeps the end, where the line budget keeps both: what is left by then
        /// is lines too long to read whole, and the last of them is where a command says how it
        /// ended.
        public var text: String {
            var lines = head
            if droppedLines > 0 { lines += ["", "[\(droppedLines) lines of this output are not shown]", ""] }
            let joined = (lines + tail).joined(separator: "\n")
            guard joined.count > Self.maxCharacters else { return joined }
            return "[the start of this output is not shown]\n" + String(joined.suffix(Self.maxCharacters))
        }

        /// A progress bar redraws its line with carriage returns, and only the last redraw is what
        /// a terminal would have left on screen. Colour is stripped because a text box has no
        /// terminal behind it, and an escape sequence costs tokens and reads as corruption.
        static func clean(_ raw: String) -> String {
            let shown = raw.split(separator: "\r").last.map(String.init) ?? ""
            let plain = CheckFailureHandoff.stripAnsi(shown)
            guard plain.count > maxLineCharacters else { return plain }
            return String(plain.prefix(maxLineCharacters)) + " [the rest of this line is not shown]"
        }
    }

    /// The message the agent receives once the command has finished.
    ///
    /// In the tags Claude Code itself writes for a `!` command, which Claude models already read as
    /// "the user ran this", and which any other agent reads as plainly as prose. They are also what
    /// lets `split` find the turn again without guessing, so the transcript can draw it as a
    /// command rather than as the text the agent was given.
    public static func message(command: String, output: Output, ending: ProcessEnding) -> String {
        "\(Tag.input)\(command)\(Tag.inputEnd)\n\(Tag.output)\(output.text)\(Tag.outputEnd)\n"
            + "\(Tag.status)\(ending.sentence)\(Tag.statusEnd)"
    }

    /// A sent command, read back out of the message `message` wrote.
    public struct Sent: Sendable, Equatable {
        public var command: String
        public var output: String
        /// How it ended, in `ProcessEnding.sentence`'s words.
        public var status: String

        public var succeeded: Bool { status == ProcessEnding.exited(0).sentence }

        /// The command as it was typed, which is what a summary shows and what Up puts back.
        public var typed: String { "! \(command)" }
    }

    /// The command a user turn carried, or nil for every turn `message` did not write. Strict, like
    /// `ReviewTurn.split`: anything not exactly that shape is drawn as the text it is. The output is
    /// read up to the last closing tag, so output that prints the tag itself is kept whole.
    public static func split(_ text: String) -> Sent? {
        guard text.hasPrefix(Tag.input), text.hasSuffix(Tag.statusEnd),
              let inputEnd = text.range(of: Tag.inputEnd + "\n" + Tag.output),
              let outputEnd = text.range(of: Tag.outputEnd + "\n" + Tag.status, options: .backwards),
              inputEnd.upperBound <= outputEnd.lowerBound
        else { return nil }
        return Sent(
            command: String(text[text.index(text.startIndex, offsetBy: Tag.input.count)..<inputEnd.lowerBound]),
            output: String(text[inputEnd.upperBound..<outputEnd.lowerBound]),
            status: String(text[outputEnd.upperBound...].dropLast(Tag.statusEnd.count))
        )
    }

    private enum Tag {
        static let input = "<bash-input>"
        static let inputEnd = "</bash-input>"
        static let output = "<bash-stdout>"
        static let outputEnd = "</bash-stdout>"
        static let status = "<bash-status>"
        static let statusEnd = "</bash-status>"
    }
}
