import Foundation

/// A picture an agent on a Bloom Cloud machine showed, as the `media` row that records it.
///
/// **A reference, never the bytes.** The row names a copy inside the worktree's own git-ignored
/// scratch folder, and a client fetches it with `download`, which is the same door as any other
/// file: a session token for this workspace with `view`, confined to the worktree, at most 8 MB.
/// Nothing about showing a picture opens a way in that the audit in docs/CLOUD-PARITY.md does not
/// already cover.
///
/// Only the record here, taken verbatim from the machine's branch so a client can read the row.
/// The half that copies a file on the machine (`sniff`, `copy`, the tool) arrives with that
/// branch, whose copy of this file replaces this one when the two meet.
public struct SharedMedia: Codable, Sendable, Hashable {
    /// Where the copy is, relative to the worktree: what `download` takes.
    public var path: String
    /// The file's own name, which is what a person recognises under the picture.
    public var name: String
    public var caption: String
    /// `image` or `video`.
    public var kind: String
    public var mime: String
    public var bytes: Int

    public init(path: String, name: String, caption: String, kind: String, mime: String, bytes: Int) {
        self.path = path
        self.name = name
        self.caption = caption
        self.kind = kind
        self.mime = mime
        self.bytes = bytes
    }
}
