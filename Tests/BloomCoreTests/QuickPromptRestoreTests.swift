import Testing
import Foundation
@testable import BloomCore

private func prompt(_ name: String, text: String = "body", order: Int = 0) -> QuickPrompt {
    QuickPrompt(name: name, symbol: "text.bubble", text: text, sortOrder: order, createdAt: Date())
}

/// The one route back to a built-in quick prompt after it has been deleted.
///
/// Deleting one was permanent: seeding is gated on a stored version, so nothing looks for a
/// deleted entry again, and nothing anywhere said so or offered anything about it. The seeding
/// rule is right and stays (`QuickPromptSeed`'s head argues it), so the way back is a thing the
/// owner asks for rather than something a launch does behind them.
@Suite("Quick prompt restore")
struct QuickPromptRestoreTests {
    // MARK: - What is missing

    @Test("a library holding every built-in is missing nothing")
    func nothingMissingWhenAllPresent() {
        let library = QuickPromptSeed.all.map { prompt($0.name, text: $0.text) }
        #expect(QuickPromptSeed.missing(from: library).isEmpty)
    }

    @Test("an empty library is missing all of them")
    func everythingMissingWhenEmpty() {
        #expect(QuickPromptSeed.missing(from: []).count == QuickPromptSeed.all.count)
    }

    /// The case the feature exists for.
    @Test("a deleted built-in is what comes back")
    func aDeletedBuiltInIsMissing() throws {
        let first = try #require(QuickPromptSeed.all.first)
        let library = QuickPromptSeed.all.dropFirst().map { prompt($0.name, text: $0.text) }

        let missing = QuickPromptSeed.missing(from: Array(library))

        #expect(missing.map(\.name) == [first.name])
    }

    /// **Matched on name and never on text.** An entry whose words the owner has rewritten is
    /// theirs now, and offering to put Bloom's wording back beside it would be this feature
    /// undoing their work rather than undoing a delete.
    @Test("a built-in the owner has edited is not missing")
    func anEditedBuiltInIsNotMissing() throws {
        let first = try #require(QuickPromptSeed.all.first)
        var library = QuickPromptSeed.all.map { prompt($0.name, text: $0.text) }
        library[0] = prompt(first.name, text: "rewritten in the owner's own words")

        #expect(!QuickPromptSeed.missing(from: library).contains { $0.name == first.name })
    }

    /// Whitespace and case are how a person types, not what they mean.
    @Test("a name matches whatever case and padding it was typed in")
    func matchingIgnoresCaseAndPadding() throws {
        let first = try #require(QuickPromptSeed.all.first)
        let library = [prompt("  " + first.name.uppercased() + "  ")]

        #expect(!QuickPromptSeed.missing(from: library).contains { $0.name == first.name })
    }

    // MARK: - The words

    /// A control for a state nothing is in teaches the reader nothing, which is the same test the
    /// sidebar applies to its hidden-projects toggle.
    @Test("nothing missing means no row at all")
    func noRowWhenNothingMissing() {
        #expect(QuickPromptSeed.restoreTitle(missing: 0) == nil)
    }

    @Test("the row counts what it would put back")
    func rowCountsWhatItRestores() {
        #expect(QuickPromptSeed.restoreTitle(missing: 1) == "Restore 1 built-in prompt")
        #expect(QuickPromptSeed.restoreTitle(missing: 3) == "Restore 3 built-in prompts")
    }

    /// The half a reader is actually weighing is what is NOT touched.
    @Test("the help says what survives")
    func helpNamesWhatSurvives() {
        #expect(QuickPromptSeed.restoreHelp.contains("Nothing you wrote"))
    }

    // MARK: - The write

    @Test("restoring puts back only what is gone", .tags(.persistence), .scratchDirectory)
    func restoreInsertsOnlyTheMissing() async throws {
        let store = try makeTestStore("quick-prompt-restore")
        let seeded = try await store.seedQuickPrompts()
        let victim = try #require(seeded.first)
        try await store.deleteQuickPrompt(id: victim.id)
        #expect(try await store.quickPrompts().count == seeded.count - 1)

        let restored = try await store.restoreBuiltInQuickPrompts()

        #expect(restored.count == seeded.count)
        #expect(restored.contains { $0.name == victim.name })
        // A new row rather than the old one resurrected: the id went with the delete.
        #expect(!restored.contains { $0.id == victim.id })
    }

    /// Pressing it twice must not leave two of everything.
    @Test("restoring twice is not two copies", .tags(.persistence), .scratchDirectory)
    func restoreIsIdempotent() async throws {
        let store = try makeTestStore("quick-prompt-restore-twice")
        let seeded = try await store.seedQuickPrompts()
        try await store.deleteQuickPrompt(id: try #require(seeded.first).id)

        _ = try await store.restoreBuiltInQuickPrompts()
        let second = try await store.restoreBuiltInQuickPrompts()

        #expect(second.count == seeded.count)
    }

    /// A prompt the owner wrote themselves is not a built-in and is never touched by this.
    @Test("a prompt the owner wrote is left alone", .tags(.persistence), .scratchDirectory)
    func ownPromptsAreUntouched() async throws {
        let store = try makeTestStore("quick-prompt-restore-own")
        _ = try await store.seedQuickPrompts()
        let mine = try await store.insert(prompt("Mine", text: "my words", order: 99))

        let restored = try await store.restoreBuiltInQuickPrompts()

        let kept = try #require(restored.first { $0.id == mine.id })
        #expect(kept.text == "my words")
    }

    /// The seed version records how far the automatic seeding has got. A restore is not that, and
    /// writing it here would mark built-ins shipped later as already offered on an old database.
    @Test("restoring does not move the seed version", .tags(.persistence), .scratchDirectory)
    func restoreLeavesTheSeedVersionAlone() async throws {
        let store = try makeTestStore("quick-prompt-restore-version")
        _ = try await store.seedQuickPrompts()
        let before = try await store.setting(QuickPromptSeed.versionKey)

        _ = try await store.restoreBuiltInQuickPrompts()

        #expect(try await store.setting(QuickPromptSeed.versionKey) == before)
    }
}
