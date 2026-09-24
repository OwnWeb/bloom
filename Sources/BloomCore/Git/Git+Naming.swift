import Foundation

/// Turning a prompt into a branch name, a stem and a title.
///
/// The one part of `Git` that never runs git: every function here is a rule about words, so the
/// tests drive them without a repository on disk. Whether the result is a name git will accept
/// is a separate question, and `isValidBranchName` in `Git.swift` is what answers it.
extension Git {
    /// What is trimmed off both ends of a branch prefix. See `prefixed`.
    private static let prefixEdges = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "/"))

    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "to", "of", "in", "on", "for", "with",
        "please", "can", "you", "i", "we", "it", "this", "that", "is", "are", "be",
        "should", "would", "could", "make", "let", "lets",
    ]

    /// Attachment paths belong to the prompt the agent reads, never to a workspace's identity.
    /// Keep other code spans, including source file paths, so they can still distinguish branches.
    private static func namingText(from prompt: String) -> String {
        AttachmentDraft.parse(prompt).segments.map { segment in
            if case .attachment(let path) = segment, path.hasPrefix(AttachmentDraft.copyPrefix) {
                return " "
            }
            return segment.text
        }.joined()
    }

    /// Turn a prompt into a branch-safe slug. Mirrors what Conductor does: take the meaningful
    /// words from the first line, cap the length, keep it readable.
    public static func slug(from prompt: String, maxWords: Int = 5) -> String {
        let firstLine = namingText(from: prompt)
            .components(separatedBy: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""

        let words = firstLine
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        var kept = words.filter { !stopWords.contains($0) && $0.count > 1 }.map(shortened)
        if kept.isEmpty { kept = words.map(shortened) }
        if kept.isEmpty { return "workspace" }

        var parts = Array(kept.prefix(maxWords))

        // A file path is usually the most distinguishing thing in a prompt, and it is exactly
        // what falls off the end of the word budget. Without this, "add a docblock to Invoice.php"
        // and "... to Contact.php" produce the same branch, and the collision suffix (-2, -3)
        // leaves a sidebar full of names that say nothing about which is which.
        if let token = distinguishingToken(from: firstLine).map(shortened), !parts.contains(token) {
            parts.append(token)
        }

        return String(parts.joined(separator: "-").prefix(60))
    }

    /// The longest one word a branch keeps.
    ///
    /// **Twenty four characters, and the number is about what somebody reads rather than a round
    /// figure.** A branch is read in `git branch`, in a pull request's title bar and in a terminal
    /// prompt, always beside other text, so the budget that matters is the whole ref: five words
    /// and sixty characters under a prefix like `freekmurze/` is already about seventy, which is
    /// most of a terminal line. One word may take a good share of that and no more. Twenty four
    /// keeps the longest things anybody genuinely names, `WorkspaceConnectionTests` is exactly
    /// twenty four and `laravel-medialibrary` is twenty, and cuts what is not a word at all: the
    /// owner typed ninety characters of keyboard mashing to see what would happen, and a sixty
    /// character run of it is not reasonable merely because it is one token.
    ///
    /// The cut is blind because there is nothing to cut on: a token with no boundary in it has no
    /// better place to stop.
    static let longestWord = 24

    private static func shortened(_ word: String) -> String {
        word.count > longestWord ? String(word.prefix(longestWord)) : word
    }

    /// The basename of the first path-like token in a line, lowercased and hyphenated.
    static func distinguishingToken(from line: String) -> String? {
        let separators = CharacterSet(charactersIn: " \t,;()[]{}\"'`")
        for token in line.components(separatedBy: separators) where !token.isEmpty {
            let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: ".:"))
            let base = (trimmed as NSString).lastPathComponent
            let stem = (base as NSString).deletingPathExtension
            let ext = (base as NSString).pathExtension

            // Either an actual path, or something that really looks like a filename. A bare
            // sentence ending in a full stop must not qualify.
            let looksLikePath = trimmed.contains("/")
            let looksLikeFile = !ext.isEmpty && ext.count <= 5
                && ext.allSatisfy(\.isLetter) && stem.count >= 3
            guard looksLikePath || looksLikeFile else { continue }

            let cleaned = stem
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: "-")
            if cleaned.count >= 2 { return cleaned }
        }
        return nil
    }

    /// A human-facing workspace name: the first line, trimmed and sentence-cased.
    public static func title(from prompt: String, maxLength: Int = 72) -> String {
        let firstLine = namingText(from: prompt)
            .components(separatedBy: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !firstLine.isEmpty else { return "New workspace" }

        var title = firstLine
        if title.count > maxLength {
            let cut = title.prefix(maxLength)
            if let lastSpace = cut.lastIndex(of: " ") {
                title = String(cut[..<lastSpace])
            } else {
                title = String(cut)
            }
        }
        return title.prefix(1).uppercased() + title.dropFirst()
    }

    /// Append -2, -3 and so on until the branch name is free.
    /// The branch a prompt would be cut on, before anything checks whether it is free.
    ///
    /// One function because two places need the same answer and only one of them can act on it:
    /// `WorkspaceManager.cut` puts a worktree on it, and the create window prints it under the box
    /// so somebody can see what they are about to make. Those were two copies of the same three
    /// lines, one of them carrying a comment saying it mirrored the other, which is a drift waiting
    /// for the next change to either side. A preview that has drifted is a lie in a monospaced font.
    ///
    /// An explicit branch is returned untouched, prefix and all: somebody who typed a branch name
    /// meant that branch name. The uniquing suffix is deliberately not here, because it depends on
    /// what the repository holds at the moment of cutting and the preview has no business guessing.
    public static func branchStem(prompt: String, prefix: String?, branch: String? = nil) -> String {
        if let branch, !branch.isEmpty { return branch }
        return prefixed(Self.slug(from: prompt), with: prefix)
    }

    /// A branch name under a project's `branchPrefix`.
    ///
    /// Three lines, and it is a function because there were three copies of them: here, in
    /// `WorkspaceNaming.cleanBranch` where a model's suggestion is prefixed, and in the app where
    /// a claimed sea's slug is. The third carried a comment saying it applied the same rule as the
    /// second, which it did by writing it out again, under a comment on this one warning about
    /// exactly that. What a prefix means is decided here, and only here.
    ///
    /// An empty prefix is no prefix. A project that has never set one and one that set it to ""
    /// are the same project.
    ///
    /// The prefix is normalised before the slash is added, because a prefix ending in one
    /// produced `feature//test`, which the create window printed under the name box and which
    /// `git branch` then refused with "'feature//test' is not a valid branch name": an empty
    /// component between two slashes is not a ref. A prefix is a prefix whether or not somebody
    /// wrote the separator themselves, and people write it, so whitespace and slashes at either
    /// end come off and a prefix that was nothing but those is no prefix rather than a leading
    /// slash. Normalising here rather than at the settings field is what matters: a `feature/`
    /// already sitting in a project's `.bloom/settings.toml` is never seen by that field again.
    ///
    /// Only the edges. A prefix with a space or a colon in the middle of it is still a prefix git
    /// will refuse, and silently rewriting the owner's own text into something else is a larger
    /// decision than repairing a separator that was going to be supplied anyway.
    public static func prefixed(_ slug: String, with prefix: String?) -> String {
        guard let prefix else { return slug }
        let trimmed = prefix.trimmingCharacters(in: prefixEdges)
        guard !trimmed.isEmpty else { return slug }
        return "\(trimmed)/\(slug)"
    }

    public static func uniqueBranch(_ desired: String, taken: Set<String>) -> String {
        guard taken.contains(desired) else { return desired }
        var suffix = 2
        while taken.contains("\(desired)-\(suffix)") { suffix += 1 }
        return "\(desired)-\(suffix)"
    }
}
