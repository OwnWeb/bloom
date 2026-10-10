import SwiftUI
import BloomCore

/// Settings, Models, Automatic router: whether new workspaces are routed, who reads the task, on
/// which model, and each agent's table.
///
/// Every row but the switch starts on Bloom's own suggestion and stores nothing until it is
/// changed, so a suggestion goes on improving as an agent's list of models does. See
/// `ModelRouterSettings`, which holds the rules for what is stored, and `RouterAnalyser` and
/// `ModelRouterTable`, which hold the suggestions.
///
/// Only agents that are signed in are listed. An agent with no account cannot read a task, and a
/// row for it would be a choice that does nothing. See `AgentAvailability`.
struct RouterSettingsSection: View {
    @State private var isEnabled = ModelRouterPreferences().isEnabled
    @State private var settings = ModelRouterPreferences().settings

    private var catalog: ComposerModelCatalog { .shared }

    /// The agents the router can ask, in the order Bloom offers agents everywhere else.
    private var agents: [AgentKind] {
        AgentKind.runnable.filter { AgentAvailability.shared.connected.contains($0) }
    }

    var body: some View {
        Section {
            Toggle(isOn: $isEnabled) {
                Text("Choose the model for each new workspace")
                Text("A light model reads the first message, without accessing your code, and picks a model and reasoning effort for it before the conversation starts.")
            }

            if isEnabled {
                if agents.isEmpty {
                    Text(emptyNote)
                        .settingsFootnote()
                } else {
                    Picker(selection: $settings.analyser) {
                        Text("The chat's own agent").tag(ModelRouterSettings.Analyser.followChat)
                        ForEach(agents) { kind in
                            Text(kind.label).tag(ModelRouterSettings.Analyser.agent(kind))
                        }
                    } label: {
                        Text("Read the task with")
                        Text("When that agent is signed out, the first signed in one reads it instead.")
                    }

                    ForEach(agents) { kind in
                        SettingsRow("\(kind.label) reader") {
                            RouterChoicePicker(
                                kind: kind,
                                choice: analyserChoice(for: kind),
                                suggestion: suggestedAnalyser(for: kind)
                            )
                        }
                    }

                    DisclosureGroup("Routing tables") {
                        ForEach(agents) { kind in
                            RouterTableEditor(kind: kind, settings: $settings)
                        }
                    }
                }
            }
        } header: {
            Text("Automatic router")
        } footer: {
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                Text("A model or effort picked by hand in the new workspace window always wins. The router never moves a chat to another agent.")
                    .settingsFootnote()
                if isEnabled {
                    ForEach(agents) { kind in
                        Text(ModelRouteCaption.safetyNote(for: kind))
                            .settingsFootnote()
                    }
                }
            }
        }
        .onChange(of: isEnabled) { _, value in
            ModelRouterPreferences().isEnabled = value
            if value { AgentAvailability.shared.refreshIfStale() }
        }
        .onChange(of: settings) { _, value in
            ModelRouterPreferences().settings = value
        }
        .task {
            if isEnabled { AgentAvailability.shared.refreshIfStale() }
        }
    }

    private var emptyNote: String {
        AgentAvailability.shared.hasLoaded
            ? "No signed in agent can read tasks yet. Sign in to one under Agents."
            : "Looking for signed in agents\u{2026}"
    }

    private func suggestedAnalyser(for kind: AgentKind) -> ModelRouteChoice {
        let suggested = RouterAnalyser.analyser(on: kind, stored: nil, models: catalog.models[kind] ?? [])
        return ModelRouteChoice(model: suggested.model, effort: suggested.effort)
    }

    private func analyserChoice(for kind: AgentKind) -> Binding<ModelRouteChoice?> {
        Binding(
            get: { settings.analyserModels[kind] },
            set: { settings.analyserModels[kind] = $0 }
        )
    }
}

/// One agent's table: a row per rung, each on the suggestion until it is changed, and a reset.
private struct RouterTableEditor: View {
    let kind: AgentKind
    @Binding var settings: ModelRouterSettings

    private var catalog: ComposerModelCatalog { .shared }

    private var suggested: ModelRouterTable? {
        ModelRouterTable.suggested(for: kind, models: catalog.models[kind] ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            HStack {
                Text(kind.label)
                    .font(Typo.labelEmphasis)
                Spacer(minLength: 0)
                if settings.tables[kind] != nil {
                    Button("Reset") { settings.tables[kind] = nil }
                        .linkButton()
                        .font(Typo.caption)
                }
            }
            if let suggested {
                ForEach(TaskComplexity.allCases, id: \.self) { rung in
                    SettingsRow(rung.label) {
                        RouterChoicePicker(
                            kind: kind,
                            choice: choice(for: rung),
                            suggestion: suggested.choice(for: rung)
                        )
                    }
                }
            } else {
                Text("\(kind.label)'s models have not been listed yet, so there is nothing to route between.")
                    .settingsFootnote()
            }
        }
        .padding(.vertical, Metrics.spacingSmall)
    }

    /// A rung set back to the suggestion leaves the table, and an empty table leaves the settings,
    /// so Reset only shows while something is actually changed.
    private func choice(for rung: TaskComplexity) -> Binding<ModelRouteChoice?> {
        Binding(
            get: { settings.tables[kind]?[rung] },
            set: { value in
                var rungs = settings.tables[kind] ?? [:]
                rungs[rung] = value
                settings.tables[kind] = rungs.isEmpty ? nil : rungs
            }
        )
    }
}

/// A model and an effort on one agent, or Bloom's suggestion. Nil is the suggestion, and picking
/// the suggestion row again puts the choice back to nil rather than storing a copy of it.
private struct RouterChoicePicker: View {
    let kind: AgentKind
    @Binding var choice: ModelRouteChoice?
    let suggestion: ModelRouteChoice

    private var catalog: ComposerModelCatalog { .shared }

    /// The suggestion's row. Its tag is empty, which no model id is.
    private static let suggestedTag = ""

    private var models: [ComposerOption] {
        ComposerOption.adding([choice?.model ?? ""], to: catalog.options(for: kind))
    }

    private var efforts: [ComposerOption] {
        guard let choice else { return [] }
        return ComposerOption.adding([choice.effort], to: catalog.efforts(for: kind, model: choice.model))
    }

    var body: some View {
        HStack(spacing: Metrics.gutter) {
            Picker("Model", selection: model) {
                Text("Suggested: \(label(of: suggestion))").tag(Self.suggestedTag)
                ForEach(models) { option in
                    Text(option.label).tag(option.id)
                }
            }
            .labelsHidden()
            .fixedSize()

            if choice != nil, !efforts.isEmpty {
                Picker("Effort", selection: effort) {
                    ForEach(efforts) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private func label(of choice: ModelRouteChoice) -> String {
        let name = catalog.options(for: kind).first { $0.id == choice.model }?.label
            ?? (choice.model.isEmpty ? "\(kind.label)'s default" : ModelLabel.readable(choice.model))
        guard !choice.effort.isEmpty else { return name }
        return "\(name), \(ModelRouteCaption.effortLabel(choice.effort).lowercased())"
    }

    /// Choosing a model keeps the effort where the new model takes it and moves it to the model's
    /// own default where it does not, which is the composer's rule. See `ModelAndEffortPickers`.
    private var model: Binding<String> {
        Binding(
            get: { choice?.model ?? Self.suggestedTag },
            set: { id in
                MainActor.assumeIsolated {
                    guard id != Self.suggestedTag else {
                        choice = nil
                        return
                    }
                    let wanted = choice?.effort ?? suggestion.effort
                    choice = ModelRouteChoice(
                        model: id,
                        effort: catalog.resolvedEffort(wanted, for: kind, model: id)
                    )
                }
            }
        )
    }

    private var effort: Binding<String> {
        Binding(
            get: { choice?.effort ?? "" },
            set: { level in
                MainActor.assumeIsolated {
                    guard let current = choice else { return }
                    choice = ModelRouteChoice(model: current.model, effort: level)
                }
            }
        )
    }
}
