import SwiftUI
import Observation
import BloomCore

/// What the reader is writing into a code block of the transcript, kept outside the block.
///
/// **Not `@State`, because a transcript row is not a place to keep anything.** The table recycles
/// a row once it scrolls out of sight and builds it again on the way back, and a relaunch builds
/// all of them again, so an edit held by the fence was twenty five minutes of work lost to a
/// scroll. Each draft is its own user defaults key, written on every change and removed once it
/// is attached or discarded, so a keystroke writes one string rather than every draft there is.
///
/// One box per block, for `PromptAttachmentStore`'s reason: a dictionary is one observed property,
/// and a keystroke in one fence would rebuild every fence on screen.
@MainActor
final class CodeBlockDraftStore {
    static let shared = CodeBlockDraftStore()

    @Observable
    final class Draft {
        var text: String?
    }

    private var drafts: [String: Draft] = [:]

    private init() {}

    /// The box a block's draft lives in. Made on the spot, which is safe from a body because the
    /// map is not observed: see `PromptAttachmentStore.box`.
    func draft(for key: String) -> Draft {
        if let held = drafts[key] { return held }
        let made = Draft()
        made.text = UserDefaults.standard.string(forKey: Self.defaultsKey(key))
        drafts[key] = made
        return made
    }

    func set(_ text: String?, for key: String) {
        draft(for: key).text = text
        if let text {
            UserDefaults.standard.set(text, forKey: Self.defaultsKey(key))
        } else {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey(key))
        }
    }

    private static func defaultsKey(_ key: String) -> String { "transcript.codeBlockDraft.\(key)" }
}
