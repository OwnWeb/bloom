import BloomCore

/// The one pane's worth of `WorkspaceModel.panePositions` a transcript list is allowed to read and
/// write.
///
/// A pass-through rather than a store of its own, and it exists so that the list does not have to
/// be handed a whole `WorkspaceModel` to remember where it was. Two views between the pane and the
/// list would then be carrying a model neither of them draws anything from, and a `@Bindable` one
/// at that.
///
/// The pane id is half the key because a split tab can hold the same conversation twice, each half
/// scrolled somewhere else. It is the pane's own string, which for an unsplit tab is the tab's id
/// and therefore the session's uuid; `CentrePaneMeasure.soloPane` is a `ForEach` identity and is
/// never what a pane is called. A comment here said the opposite for months, and cost an
/// afternoon: a probe read that key, found nothing, and was believed. See `TranscriptPaneState.Key`.
///
/// Nil for a transcript nobody can scroll back to: the archive sheet draws one and is gone.
/// Two closures rather than a workspace and a pane id, so a workspace of either kind can hand one
/// over: a local one reads and writes `WorkspaceModel.panePositions`, a Cloud one its session's own.
/// See `WorkspaceSurface.transcriptMemory(pane:)`.
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
