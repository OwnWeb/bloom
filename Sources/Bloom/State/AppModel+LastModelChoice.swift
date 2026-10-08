import BloomCore
import Foundation

/// Remembering the model somebody picked, so the next workspace opens on it. See `LastModelChoice`
/// for where it ranks against Settings and a default preset.
extension AppModel {
    /// Called by every footer when its controls change. Only a move of the model, the effort or
    /// the backend is written: the footer also reports fast mode, the output style and the
    /// permission mode, and none of those is a model choice.
    func rememberModelChoice(from old: ComposerControls, to new: ComposerControls) {
        let choice = LastModelChoice(new)
        guard choice != LastModelChoice(old), let store else { return }
        Task { try? await choice.save(to: store) }
    }
}
