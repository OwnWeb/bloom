import Foundation

/// What the Bloom Cloud create sheet's "from main" list offers: the project's branches as
/// runbloom.app pages them, searched on its side, with the default branch first and whatever was
/// typed still usable.
///
/// **The default first**, because it is what a new branch is ordinarily cut from and the one
/// somebody opening the list is most likely to want; the local sheet's list keeps it at the top
/// for the same reason.
///
/// **A typed name is always a row**, after whatever matched it, when it is a name git would take
/// and nothing listed is spelled that way. A branch pushed a moment ago may not be listed yet, and
/// a list that could only pick what it had loaded would be a list that could not be trusted to
/// name the branch somebody knows is there.
///
/// **Answers for a query nobody is asking any more are dropped.** Searching is runbloom.app's,
/// one ask per settled query, and the answer to "ma" arriving after "main" was typed must not
/// replace the list for "main".
public struct CloudBaseBranches: Sendable, Equatable {
    public enum Load: Sendable, Equatable {
        case idle
        case loading
        case loaded
        /// Could not be listed, with runbloom.app's reason or the transport's.
        case failed(String)
    }

    public var defaultBranch: String
    public private(set) var query = ""
    public private(set) var loaded: [String] = []
    /// Where the next page starts, when runbloom.app said there is one.
    public private(set) var next: String?
    public private(set) var load: Load = .idle

    public init(defaultBranch: String) {
        self.defaultBranch = defaultBranch
    }

    /// A new search. The list empties and waits for its first page.
    public mutating func search(_ text: String) {
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        loaded = []
        next = nil
        load = .loading
    }

    /// A page for `query`. Ignored when the search has moved on since it was asked.
    public mutating func receive(_ names: [String], next: String?, for query: String) {
        guard query == self.query else { return }
        for name in names where !loaded.contains(name) { loaded.append(name) }
        self.next = next
        load = .loaded
    }

    public mutating func fail(_ reason: String, for query: String) {
        guard query == self.query else { return }
        load = .failed(reason)
    }

    /// Asking for the next page of the same search.
    public mutating func loadingMore() {
        load = .loading
    }

    /// The branch names to draw, in order.
    public var rows: [String] {
        var names: [String] = []
        if !defaultBranch.isEmpty, query.isEmpty || defaultBranch.localizedCaseInsensitiveContains(query) {
            names.append(defaultBranch)
        }
        for name in loaded where !names.contains(name) { names.append(name) }
        if let typed, !names.contains(typed) { names.append(typed) }
        return names
    }

    /// What was typed, when it could be a branch at all. See the note on the type.
    public var typed: String? {
        guard !query.isEmpty, CloudBranchName.problem(query) == nil else { return nil }
        return query
    }

    /// How long to wait before asking again, when runbloom.app said too many requests; nil for any
    /// other refusal, which is shown as it is.
    ///
    /// **A limit is waited out quietly, not shown.** It is thirty lists a minute per person, shared
    /// with the web, and somebody refining a search with pauses between the words can meet it
    /// without doing anything wrong, so the rows already on screen stay and the list asks again
    /// once runbloom.app's `retry_after` has passed. Bounded at a minute, so a wild value cannot
    /// leave the list spinning, and at least a second, so a zero cannot make it ask in a loop.
    public static func retryDelay(for error: any Error) -> Duration? {
        guard let refusal = error as? RunbloomRefusal, refusal.status == 429 else { return nil }
        return .seconds(min(max(refusal.retryAfter ?? 5, 1), 60))
    }

    /// Whether the row for `name` is only there because it was typed.
    public func isTyped(_ name: String) -> Bool {
        name == typed && !loaded.contains(name) && name != defaultBranch
    }
}
