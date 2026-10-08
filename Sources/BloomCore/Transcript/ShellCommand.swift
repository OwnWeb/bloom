import Foundation

/// A composer draft that starts with `!`: a shell command run in the worktree rather than a message,
/// whose output goes to the agent as the next message once it has finished.
///
/// This is Claude Code's shell mode, done by Bloom. stream-json has no such mode, and Codex and Grok
/// have nothing like it either, so the output reaches the agent as an ordinary user message and every
/// agent gets it the same way. The agent answers it, which is the point: `! npm test` gets an
/// explanation of the failures without a second prompt.
public enum ShellCommand {
    /// The command a draft asks to run, or nil when the draft is a message.
    ///
    /// The `!` has to be the first character, as in Claude Code, so a message that merely contains
    /// one further in is never run. A lone `!` is nil: there is nothing to run.
    public static func command(in draft: String) -> String? {
        guard draft.hasPrefix("!") else { return nil }
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
    public static func message(command: String, output: Output, ending: ProcessEnding) -> String {
        let fence = fence(enclosing: command + output.text)
        let ran = "I ran this in the worktree:\n\n\(fence)sh\n\(command)\n\(fence)\n\nIt \(ending.sentence)"
        guard !output.isEmpty else { return ran + " and printed nothing." }
        return ran + ". Its output:\n\n\(fence)\n\(output.text)\n\(fence)"
    }

    /// A Markdown fence longer than any run of backticks inside it, so output that prints a fence of
    /// its own cannot close this one early.
    static func fence(enclosing text: String) -> String {
        var longest = 0
        var current = 0
        for character in text {
            current = character == "`" ? current + 1 : 0
            longest = max(longest, current)
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }
}
