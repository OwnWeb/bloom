import Testing
@testable import BloomCore

@Suite("Reply selection shortcut")
struct ReplySelectionShortcutTests {
    @Test("plain R quotes a selected passage in the current thread", arguments: ["r", "R"])
    func armed(character: String) {
        #expect(ReplySelectionShortcut.isArmed(
            character: character,
            modifiers: character == "R" ? [.shift] : [],
            hasSelection: true,
            isEditable: false,
            isComposing: false,
            isInCurrentThread: true
        ))
    }

    @Test(
        "command, control and option keep their ordinary meaning",
        arguments: [
            MenuShortcut.Modifiers.command,
            MenuShortcut.Modifiers.control,
            MenuShortcut.Modifiers.option,
            [MenuShortcut.Modifiers.command, .shift],
        ]
    )
    func modified(modifiers: MenuShortcut.Modifiers) {
        #expect(!ReplySelectionShortcut.isArmed(
            character: "r",
            modifiers: modifiers,
            hasSelection: true,
            isEditable: false,
            isComposing: false,
            isInCurrentThread: true
        ))
    }

    @Test(
        "typing, composition and selections elsewhere are never intercepted",
        arguments: [
            (true, false, true),
            (false, true, true),
            (false, false, false),
        ]
    )
    func context(isEditable: Bool, isComposing: Bool, isInCurrentThread: Bool) {
        #expect(!ReplySelectionShortcut.isArmed(
            character: "r",
            modifiers: [],
            hasSelection: true,
            isEditable: isEditable,
            isComposing: isComposing,
            isInCurrentThread: isInCurrentThread
        ))
    }

    @Test("another key or an empty selection stays untouched")
    func needsRAndASelection() {
        #expect(!isArmed(character: "q", hasSelection: true))
        #expect(!isArmed(character: "r", hasSelection: false))
    }

    private func isArmed(character: String, hasSelection: Bool) -> Bool {
        ReplySelectionShortcut.isArmed(
            character: character,
            modifiers: [],
            hasSelection: hasSelection,
            isEditable: false,
            isComposing: false,
            isInCurrentThread: true
        )
    }
}
