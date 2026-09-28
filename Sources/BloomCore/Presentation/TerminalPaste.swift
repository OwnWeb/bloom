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
///
/// The key goes to whatever holds the pane, and at a bare prompt Control+V is zsh's quoted-insert,
/// which swallows the next keystroke. That is accepted rather than gated: a CLI chat runs inside
/// tmux, whose pty says nothing about what is in the foreground without two subprocesses per
/// reading, and a picture pasted at a prompt meant nothing before this either.
public enum TerminalPaste: Equatable, Sendable {
    /// The terminal's own paste: the string on the board, sent to the shell.
    case text
    /// `imageKeystroke`, so the application in the pane reads the picture off the clipboard itself.
    case imageKey

    /// The Control+V, described rather than typed at the view, because SwiftTerm builds the wire
    /// form out of these three fields: the control character for a plain shell, the unmodified
    /// letter and its key code for the kitty keyboard protocol's `CSI 118;5u`.
    public struct Keystroke: Equatable, Sendable {
        public var character: String
        public var unmodifiedCharacter: String
        public var keyCode: UInt16
    }

    public static let imageKeystroke = Keystroke(character: "\u{16}", unmodifiedCharacter: "v", keyCode: 9)

    public static func action(
        items: [PastedAttachment.Offer], hasText: @autoclosure () -> Bool
    ) -> TerminalPaste {
        guard items.contains(where: { $0.imageFormat != nil }) else { return .text }
        return hasText() ? .text : .imageKey
    }
}
