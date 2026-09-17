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
/// Text still wins whenever there is any, for the reason `PastedAttachment.plan` gives: a board
/// carrying words and a picture was filled by copying a passage. A file copied in Finder pastes as
/// it always has too, because a path typed into a shell is already what dragging the file in does.
public enum TerminalPaste: Equatable, Sendable {
    /// The terminal's own paste: the string on the board, sent to the shell.
    case text
    /// Control+V, so the application in the pane reads the picture off the clipboard itself.
    case imageKey

    public static func action(for plan: PastedAttachment.Plan) -> TerminalPaste {
        switch plan {
        case .images: .imageKey
        case .text, .files: .text
        }
    }
}
