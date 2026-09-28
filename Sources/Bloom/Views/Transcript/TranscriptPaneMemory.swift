import BloomCore

@MainActor
struct TranscriptPaneMemory {
    /// Which pane this is, which a link opened from a row needs so the file lands in the half the
    /// reader is standing in. See `TranscriptLink.actions`.
    var pane: String
    var read: (SessionID) -> TranscriptPaneState?
    var write: (TranscriptPaneState, SessionID) -> Void

    func remembered(session: SessionID) -> TranscriptPaneState? { read(session) }

    func remember(_ state: TranscriptPaneState, session: SessionID) { write(state, session) }
}
