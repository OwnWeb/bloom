import Foundation

/// The three versions of a code block the reader can edit, and every rule about which is in front.
///
/// The agent's code never changes. Over it sit the edit in progress and the version last attached
/// to a message, which the block goes on showing once it is sent until the reader asks for the
/// original back. Here rather than in `CodeBlockView` because which one is shown, what counts as
/// unchanged and what may be attached are decisions, and a decision inside a view is one nothing
/// can test.
public struct CodeBlockVersions: Equatable, Sendable {
    /// The agent's code, as it is in the transcript.
    public let original: String
    /// The edit in progress, nil when the block is not being edited.
    public var draft: String?
    /// The version last attached to a message, nil while the block shows the agent's code.
    public var attached: String?

    public init(original: String, draft: String? = nil, attached: String? = nil) {
        self.original = original
        self.draft = draft
        self.attached = attached
    }

    /// What an edit starts from, and what discarding it goes back to.
    public var base: String { attached ?? original }

    public var isEditing: Bool { draft != nil }

    /// Whether there is a version of the reader's to set beside the original.
    public var hasEdits: Bool { (draft ?? attached).map { $0 != original } ?? false }

    /// Only an edit that changed something since the last attach, so the same file is not
    /// attached twice.
    public var canAttach: Bool { draft.map { $0 != base } ?? false }

    /// Whether discarding the edit would lose any of the reader's typing, and so must be asked.
    public var discardLosesWork: Bool { draft.map { $0 != base } ?? false }

    /// The editor, unless the reader is glancing at the original.
    public func showsEditor(original showsOriginal: Bool) -> Bool {
        isEditing && !(showsOriginal && hasEdits)
    }

    /// What the read-only surface shows: the agent's code, or the attached version over it.
    public func shown(original showsOriginal: Bool) -> String {
        showsOriginal ? original : base
    }

    public mutating func edit() { draft = base }

    public mutating func discard() { draft = nil }

    /// The edit, once it has arrived in a message. Attaching the agent's own code back leaves
    /// nothing of the reader's to keep showing.
    public mutating func attach() {
        guard let draft else { return }
        attached = draft == original ? nil : draft
        self.draft = nil
    }

    public mutating func revert() { attached = nil }
}
