import Foundation

/// The quick prompts a fresh copy of Bloom starts with, and the rule that stops a deleted one from
/// coming back.
///
/// **Seed once, and record that it happened.** The obvious alternative is to reconcile a built-in
/// list against the table on every launch, and it answers the question "why is the prompt I deleted
/// back again?" with "because Bloom puts it there every time you start it". Instead each built-in
/// says which seed version introduced it, the store remembers the version it last seeded, and only
/// the entries newer than that are inserted. A prompt deleted by the owner is a row that is gone,
/// nothing looks for it again, and a second built-in added later inserts itself and resurrects
/// nothing.
///
/// The version is a plain integer rather than the app's own version, because it counts changes to
/// this list and nothing else: shipping a build that adds no built-in must not reseed anything.
public enum QuickPromptSeed {
    /// One built-in, as it is written here rather than as it is stored. It has no id: the row gets
    /// one when it is inserted, so a seeded prompt is an ordinary prompt from that moment on, with
    /// nothing about it that a hand written one does not have.
    public struct Entry: Sendable, Hashable {
        public var name: String
        public var symbol: String
        public var text: String
        /// The seed version that first shipped this entry. Anything above the version a database
        /// has already seen is inserted; anything at or below it has had its chance.
        public var introducedIn: Int

        public init(name: String, symbol: String, text: String, introducedIn: Int) {
            self.name = name
            self.symbol = symbol
            self.text = text
            self.introducedIn = introducedIn
        }

        public func prompt(sortOrder: Int, now: Date = Date()) -> QuickPrompt {
            QuickPrompt(
                name: name, symbol: symbol, text: text, sortOrder: sortOrder, createdAt: now
            )
        }
    }

    /// What the store keeps the last seeded version under, in the settings table.
    public static let versionKey = "quickPrompts.seedVersion"

    // MARK: - The way back

    /// Which built-ins are not in the library, which is the one route back after a delete.
    ///
    /// **Seeding must not do this, and the head of this file says why**: a list reconciled on
    /// every launch answers "why is the prompt I deleted back again?" with "because Bloom puts it
    /// there every time you start it". So the way back is a thing the owner asks for, once, and
    /// this is what it would put back.
    ///
    /// The absence is what made it worth adding. A deleted built-in is gone for this database for
    /// good, and nothing anywhere said so or offered anything about it, so the only reading
    /// available was that Bloom had lost it. Compare `DiffScope.strandedNote`, which exists
    /// because "a comment the reader cannot find reads as a comment that has been thrown away":
    /// the same rule, one table over.
    ///
    /// **Matched on name, folded and trimmed, and never on the text.** An entry whose text the
    /// owner has edited is theirs now, and putting a second copy of Bloom's wording beside it
    /// would be this feature undoing their work rather than a delete. A renamed one counts as
    /// missing, which is the one case that can produce something that looks like a duplicate, and
    /// it is the right way round: a name is how this list is read, so a built-in name nobody can
    /// see is a built-in that is not there as far as the reader is concerned.
    public static func missing(from prompts: [QuickPrompt]) -> [Entry] {
        let taken = Set(prompts.map(Self.fold))
        return all.filter { !taken.contains(Self.fold($0.name)) }
    }

    private static func fold(_ prompt: QuickPrompt) -> String { fold(prompt.name) }

    private static func fold(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// What the row offering it says, counted so it cannot claim to restore one thing and restore
    /// four. Nil when nothing is missing, which is the normal state and wants no row at all: a
    /// control for a state nothing is in teaches the reader nothing, which is the same test
    /// `ProjectVisibility.hiddenCount` applies to its own toggle.
    public static func restoreTitle(missing count: Int) -> String? {
        guard count > 0 else { return nil }
        return "Restore \(Counted.of(count, "built-in prompt"))"
    }

    /// The sentence under it, which is about what is NOT touched.
    ///
    /// A restore lands in a list somebody has arranged, so the thing worth saying is that it adds
    /// and changes nothing, in `ArchiveDeletion.branchStanding`'s register: name what survives,
    /// because that is the half a reader is actually weighing.
    public static let restoreHelp =
        "Puts back the prompts Bloom ships with that are not in this list. "
        + "Nothing you wrote or edited is changed."

    /// The highest `introducedIn` on the list below.
    ///
    /// Derived rather than written down by hand. A constant here has to be bumped every time an
    /// entry is added, and forgetting is not harmless: the store would insert the new entry,
    /// record the old version, and insert it again on the next launch. Two tests in
    /// `QuickPromptTests` pinned that, so it would have failed CI rather than shipped, but a
    /// maximum read off the list cannot drift from the list at all, which is better than being
    /// caught drifting. Those tests now hold by construction, and are kept as the statement of
    /// what must remain true.
    public static var version: Int { all.map(\.introducedIn).max() ?? 0 }

    public static let all: [Entry] = [
        // The one Bloom ships with. It is deletable, like everything else here, and deleting it
        // sticks: see the note at the head of this file.
        Entry(
            name: "Explain changes",
            symbol: "doc.richtext",
            text: """
            Explain the changes made in this PR as HTML. Open it as a new tab in this workspace.
            """,
            introducedIn: 1
        ),
    ]

    /// The built-ins a database that last seeded `installed` has not been offered yet.
    ///
    /// Pure, so the whole of the rule can be held still by a test: seeding twice inserts nothing
    /// the second time, and a database seeded at version 1 gets only what version 2 added.
    public static func pending(installed: Int) -> [Entry] {
        all.filter { $0.introducedIn > installed }
    }
}
