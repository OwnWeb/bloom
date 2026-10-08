import Testing
import Foundation
@testable import BloomCore

/// The last footer choice feeds the next workspace, ranks below a default preset and a repository
/// pin, and never lands a chat on a Codex model the account cannot run.
@Suite("Last model choice", .scratchDirectory)
struct LastModelChoiceTests {
    static let sol = LastModelChoice(model: "gpt-5.6-sol", effort: "low", backend: .codex)

    /// What the signed in account's `model/list` answered, which does not include `gpt-5.5`.
    static let accountModels: [AgentKind: [AgentModel]] = [
        .codex: [AgentModel(id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol", isDefault: true)],
    ]

    @Test func aChoiceSurvivesTheStore() async throws {
        let store = try makeTestStore("last-model-choice-round-trip")
        #expect(await LastModelChoice.load(from: store) == nil)
        try await Self.sol.save(to: store)
        #expect(await LastModelChoice.load(from: store) == Self.sol)
    }

    @Test func theLastChoiceIsWhatANewSessionStartsOn() async throws {
        let store = try makeTestStore("last-model-choice-new-session")
        await AppDefaults(model: "sonnet", effort: "low").save(to: store)
        try await Self.sol.save(to: store)

        // Settings keeps showing its own values.
        #expect(await AppDefaults.load(from: store).model == "sonnet")

        let defaults = await AppDefaults.loadForNewSessions(from: store)
        let resolved = ComposerDefaults.resolve(repo: RepoSettings(), app: defaults)
        #expect(resolved.model == "gpt-5.6-sol")
        #expect(resolved.backend == .codex)
        #expect(resolved.effort == "low")
    }

    @Test func aDefaultPresetOutranksTheLastChoice() async throws {
        let store = try makeTestStore("last-model-choice-preset")
        try await Self.sol.save(to: store)
        let opus = ModelPreset(
            name: "Opus", model: "opus", effort: "high", backend: .claudeCode,
            permissionMode: .bypassPermissions
        )
        var list = ModelPresetList(presets: [opus])
        list.setDefault(opus.id)
        try await list.save(to: store)

        #expect(await AppDefaults.loadForNewSessions(from: store).model == "opus")
    }

    @Test func aRepositoryPinOutranksTheLastChoice() async throws {
        let store = try makeTestStore("last-model-choice-repo")
        try await Self.sol.save(to: store)
        var repo = RepoSettings()
        repo.defaultModel = "sonnet"

        let defaults = await AppDefaults.loadForNewSessions(from: store)
        #expect(ComposerDefaults.resolve(repo: repo, app: defaults).model == "sonnet")
    }

    @Test func aLastChoiceTheAccountCannotRunFallsBackToSettings() async throws {
        let store = try makeTestStore("last-model-choice-unusable")
        await AppDefaults(model: "sonnet", effort: "low").save(to: store)
        try await LastModelChoice(model: "gpt-5.5", effort: "medium", backend: .codex).save(to: store)

        let defaults = await AppDefaults.loadForNewSessions(from: store, models: Self.accountModels)
        #expect(defaults.model == "sonnet")
    }

    @Test func aPinnedModelTheAccountCannotRunFallsBackToTheBuiltIn() {
        var repo = RepoSettings()
        repo.defaultModel = "gpt-5.5"

        let resolved = ComposerDefaults.resolve(
            repo: repo,
            app: AppDefaults(model: "gpt-5.5", backend: .codex),
            models: Self.accountModels
        )
        #expect(resolved.model == AppDefaults.fallbackModel)
        #expect(resolved.backend == .claudeCode)
    }

    @Test func aModelOnTheListIsKept() {
        let resolved = ComposerDefaults.resolve(
            repo: RepoSettings(),
            app: AppDefaults(model: "gpt-5.6-sol", effort: "low", backend: .codex),
            models: Self.accountModels
        )
        #expect(resolved.model == "gpt-5.6-sol")
        #expect(resolved.backend == .codex)
    }

    /// An empty list means the fetch has not answered, which is not the same as nothing allowed.
    @Test func anUnfetchedListDisqualifiesNothing() {
        #expect(ModelAvailability.isUsable(model: "gpt-5.5", on: .codex, models: [:]))
        #expect(ModelAvailability.isUsable(model: "gpt-5.5", on: .codex, models: [.codex: []]))
        #expect(!ModelAvailability.isUsable(model: "gpt-5.5", on: .codex, models: Self.accountModels))
        // Claude Code ids cannot be checked against a list, so they are never refused.
        #expect(ModelAvailability.isUsable(model: "opus-5-1m", on: .claudeCode, models: Self.accountModels))
    }
}
