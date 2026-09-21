import Foundation

/// Whether a plain R press should quote the selected passage of the current conversation.
///
/// This is intentionally stricter than a normal keyboard shortcut. The key is an ordinary typed
/// character, so it belongs to Bloom only while a non-editable transcript selection owns the
/// keyboard. Any editor, composition session, modified press or selection elsewhere keeps it.
public enum ReplySelectionShortcut {
    public static func isArmed(
        character: String?,
        modifiers: MenuShortcut.Modifiers,
        hasSelection: Bool,
        isEditable: Bool,
        isComposing: Bool,
        isInCurrentThread: Bool
    ) -> Bool {
        guard character?.lowercased() == "r" else { return false }
        let disallowed: MenuShortcut.Modifiers = [.command, .control, .option]
        return modifiers.isDisjoint(with: disallowed)
            && hasSelection
            && !isEditable
            && !isComposing
            && isInCurrentThread
    }
}
