/// What Command+V means in a terminal pane, decided from what the clipboard is offering.
///
/// A terminal's paste is a string: SwiftTerm reads the text off the board and sends it, bracketed,
/// and a screenshot copied rather than saved carries no text at all, so Command+V in a pane running
/// Claude Code did nothing. Not a beep, not a message, and the same clipboard pasted into the
/// composer a tab over.
///
/// The CLIs never expected the terminal to hand them a picture. Claude Code, Codex and Gemini all
/// read the clipboard themselves when they see Control+V, which is the key their own help names
/// for pasting an image, and the reason it is Control rather than Command is that Command+V is
/// answered by the terminal and never reaches them. So a Command+V the terminal cannot answer
/// becomes the Control+V the application in the pane can, and the picture arrives the way that
/// application already knows how to take it.
///
/// This is not `PastedAttachment.plan`, whose "files win" rule is about which name a chip gets.
/// The only question here is whether the CLI's own read of the clipboard will find a picture, and
/// it will exactly when picture bytes are on the board. A CleanShot capture saved to disk arrives
/// as a file URL and as PNG, so it is handed over; a file copied in Finder carries no picture bytes
/// and pastes as it always has. Text still wins whenever there is any, for the reason the composer
/// gives, and it is read only once a picture has been found, because reading it copies the whole
/// clipboard and a plain paste is about to copy it again.
public enum TerminalPaste: Equatable, Sendable {
    /// The terminal's own paste: the string on the board, sent to the shell.
    case text
    /// Control+V, so the application in the pane reads the picture off the clipboard itself.
    case imageKey

    public static func action(
        items: [PastedAttachment.Offer], hasText: @autoclosure () -> Bool
    ) -> TerminalPaste {
        guard items.contains(where: { $0.imageFormat != nil }) else { return .text }
        return hasText() ? .text : .imageKey
    }
}
