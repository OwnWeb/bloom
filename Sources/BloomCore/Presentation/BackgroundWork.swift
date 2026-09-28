import Foundation

/// The sentence under a finished turn that says the agent is not finished, and the one after an
/// archive that says what it stopped.
///
/// **The bug: "Completed in 5m 44s" with the tab still breathing.** The agent put a
/// `gh run watch` in the background, ended its turn with "#212 is still in CI, once it's green
/// I'll merge it", and the footer said Completed. The tab's activity mark stayed on, because
/// `SubagentRoster.isWorking` counted a backgrounded shell command as work in flight. Seven minutes
/// later the command finished and the CLI started a turn of its own. Nothing was wrong, and nothing
/// on screen said so: the only trace of the command was a truncated row forty lines up. The owner
/// took a screenshot and asked what was still going on.
///
/// The activity mark has since stopped counting commands, because a `serve` never finishes and
/// kept a workspace busy and unarchivable with no agent left in it. So this sentence is now the
/// only place a running command shows, which is the reason it stays.
///
/// Named rather than counted, because "1 background command" answers the question with another
/// one. `description` is the phrase the agent wrote for the Bash call, "Wait for the PR's Test run
/// to finish", which is exactly the sentence somebody wants here.
///
/// **The note is two lines and the name goes in the loud one.** It read
///
///     A background command running
///     Wait for the test.38 build.
///
/// which put the generic noun in the emphasised line somebody scans and the one fact they came
/// for in the quietest ink on the plate: the opposite of the paragraph above. One running task,
/// which is nearly always the case, now leads with its own name and demotes the noun and the
/// clock beneath it. More than one keeps the count in the lead, because the names no longer fit
/// there.
public enum BackgroundWork {
    /// The two lines drawn under the turn: what is running, then what kind of thing it is and for
    /// how long.
    public struct Note: Hashable, Sendable {
        /// The line drawn large: the task's own name, or the count when there is more than one.
        public let title: String
        /// The quiet line, without the clock. `detail(at:)` is what the view draws.
        let subtitle: String
        /// When the one running task started, or nil when there are several, whose clocks differ
        /// and would need a row each to say honestly.
        ///
        /// A start rather than a rendered duration, so a `tool_progress` tick a second does not
        /// make a new `Note` and rebuild the transcript's table under it. See
        /// `TranscriptModel.backgroundWork`, whose whole reason for existing is that cost.
        let since: Date?

        init(title: String, subtitle: String, since: Date? = nil) {
            self.title = title
            self.subtitle = subtitle
            self.since = since
        }

        /// Whether the quiet line carries a clock, and so whether the view has to redraw it.
        public var isTimed: Bool { since != nil }

        /// The quiet line at this moment: the noun, and the clock once there is one to read.
        ///
        /// Nothing is said while the count is under a second, because "running 0s" is a clock
        /// that has not started rather than a wait anybody can feel.
        public func detail(at now: Date) -> String {
            guard let since else { return subtitle }
            let elapsed = SubagentRow.duration(max(0, Int(now.timeIntervalSince(since))))
            return elapsed.isEmpty ? "\(subtitle), running" : "\(subtitle), running \(elapsed)"
        }
    }

    /// More names than this and the sentence is a list, so the rest are counted.
    static let namedLimit = 3

    /// What is still running, or nil when nothing is.
    public static func note(for roster: SubagentRoster) -> Note? {
        note(for: roster.subagents)
    }

    static func note(for subagents: [Subagent]) -> Note? {
        let running = subagents.filter { $0.state == .running }
        guard case let (counted, names)? = described(running) else { return nil }
        guard let only = running.first, running.count == 1 else {
            return Note(title: "\(capitalised(counted)) still running", subtitle: names)
        }
        // The noun has to be capitalised here rather than written that way, because the same word
        // is said mid-sentence by the archive notice and by the pane's subtitle.
        return Note(
            title: names,
            subtitle: capitalised(only.kind.noun),
            since: only.startedAt
        )
    }

    /// The notice after an archive that stopped background commands, or nil when it stopped none.
    ///
    /// An archive with nothing else at stake no longer asks before stopping a command, so this is
    /// where somebody finds out that the server on their port went with the workspace. Said after
    /// rather than asked before, because a dev server in a worktree about to be deleted is not a
    /// thing anybody would keep.
    public static func archived(_ workspaceName: String, stopping commands: [Subagent]) -> String? {
        guard case let (counted, names)? = described(commands) else { return nil }
        return "\(workspaceName) was archived. It stopped \(counted): \(names)."
    }

    /// "a background command" or "2 background commands", and the names that follow it.
    private static func described(_ subagents: [Subagent]) -> (counted: String, names: String)? {
        guard let first = subagents.first else { return nil }

        let noun = subagents.allSatisfy { $0.kind == first.kind } ? first.kind.noun : "background task"
        let counted = subagents.count == 1
            ? "\(article(for: noun)) \(noun)"
            : "\(subagents.count) \(plural(noun))"

        let titles = subagents.map(SubagentRow.title(of:))
        let named = Array(titles.prefix(namedLimit))
        let rest = titles.count - named.count
        let names = rest > 0
            ? named.joined(separator: ", ") + " and \(rest) more"
            : list(named)
        return (counted, names)
    }

    /// "a background command" rather than "1 background command", which reads as a count of
    /// something the sentence is about to name anyway.
    private static func article(for noun: String) -> String {
        noun.first.map { "aeiou".contains($0) } == true ? "an" : "a"
    }

    private static func capitalised(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    private static func plural(_ noun: String) -> String { noun + "s" }

    private static func list(_ items: [String]) -> String {
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }
}
