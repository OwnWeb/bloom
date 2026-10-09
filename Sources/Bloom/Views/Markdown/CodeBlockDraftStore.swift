import SwiftUI
import Observation
import CryptoKit
import BloomCore

/// What the reader is writing into a code block of the transcript, kept outside the block.
///
/// **Not `@State`, because a transcript row is not a place to keep anything.** The table recycles
/// a row once it scrolls out of sight and builds it again on the way back, and a relaunch builds
/// all of them again, so an edit held by the fence was twenty five minutes of work lost to a
/// scroll. It is written to user defaults on every change, for the reason `PromptAttachmentStore`
/// keeps its list there: small, worth having after a relaunch, and gone once it is attached or
/// discarded.
///
/// One box per block for that store's reason too: a dictionary is one observed property, and a
/// keystroke in one fence would rebuild every fence on screen.
@MainActor
final class CodeBlockDraftStore {
    static let shared = CodeBlockDraftStore()

    @Observable
    final class Draft {
        var text: String?
    }

    private var drafts: [String: Draft] = [:]
    private lazy var stored: [String: String] =
        UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]

    private static let defaultsKey = "transcript.codeBlockDrafts"

    private init() {}

    /// Which block a draft belongs to: the conversation, the row, and the code itself, because a
    /// row can hold several fences and nothing else tells them apart. Hashed so the key stays
    /// short whatever the fence holds, and SHA-256 rather than `hashValue`, which changes on every
    /// launch and would orphan every draft a relaunch was meant to keep.
    static func key(session: SessionID, entry: TranscriptEntryID?, code: String) -> String {
        let digest = SHA256.hash(data: Data(code.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "\(session.rawValue)/\(entry.map(String.init(describing:)) ?? "-")/\(digest)"
    }

    /// The box a block's draft lives in. Made on the spot, which is safe from a body because the
    /// map is not observed: see `PromptAttachmentStore.box`.
    func draft(for key: String) -> Draft {
        if let held = drafts[key] { return held }
        let made = Draft()
        made.text = stored[key]
        drafts[key] = made
        return made
    }

    func set(_ text: String?, for key: String) {
        draft(for: key).text = text
        stored[key] = text
        UserDefaults.standard.set(stored, forKey: Self.defaultsKey)
    }
}
