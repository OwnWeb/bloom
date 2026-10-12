import SwiftUI
import BloomCore

/// Every rung of the table, while the opening message is the only thing asked; picking one
/// re-sends it on that model. See `TranscriptModel.rerunOpening(on:)`.
struct ModelRouteChangeMenu: View {
    var current: ModelRoute
    var choices: [ModelRoute]
    var onChoose: (ModelRoute) -> Void

    var body: some View {
        Menu {
            ForEach(choices, id: \.complexity) { choice in
                // A toggle so the menu draws its own tick beside the rung the chat is on.
                let isCurrent = choice.model == current.model && choice.effort == current.effort
                Toggle(
                    "\(choice.complexity.label): \(ModelRouteCaption.title(route: choice, isSettled: true))",
                    isOn: Binding(get: { isCurrent }, set: { picked in if picked { onChoose(choice) } })
                )
                .disabled(isCurrent)
            }
        } label: {
            Text("Change")
                .font(Typo.caption)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(Palette.link)
        .pointerStyle(.link)
        .help("Stops this run and sends the opening message again on another model")
    }
}
