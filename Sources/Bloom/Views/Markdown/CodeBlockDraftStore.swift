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
/// What was last attached is kept beside it, under a key of its own, because the block goes on
/// showing the reader's version once it has been sent until they ask for the original back.
///
/// One box per block, for `PromptAttachmentStore`'s reason: a dictionary is one observed property,
/// and a keystroke in one fence would rebuild every fence on screen.
@MainActor
final class CodeBlockDraftStore {
    static let shared = CodeBlockDraftStore()

    @Observable
    final class Draft {
        /// The edit in progress, nil when the block is not being edited.
        var text: String?
        /// The version last attached to a message, nil while the block shows the agent's code.
        var attached: String?
    }

    private var drafts: [String: Draft] = [:]

    private init() {}

    /// The box a block's draft lives in. Made on the spot, which is safe from a body because the
    /// map is not observed: see `PromptAttachmentStore.box`.
    func draft(for key: String) -> Draft {
        if let held = drafts[key] { return held }
        let made = Draft()
        made.text = UserDefaults.standard.string(forKey: Self.defaultsKey(key))
        made.attached = UserDefaults.standard.string(forKey: Self.attachedKey(key))
        drafts[key] = made
        return made
    }

    func set(_ text: String?, for key: String) {
        draft(for: key).text = text
        Self.write(text, to: Self.defaultsKey(key))
    }

    func setAttached(_ text: String?, for key: String) {
        draft(for: key).attached = text
        Self.write(text, to: Self.attachedKey(key))
    }

    private static func write(_ text: String?, to defaultsKey: String) {
        if let text {
            UserDefaults.standard.set(text, forKey: defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
    }

    private static func defaultsKey(_ key: String) -> String { "transcript.codeBlockDraft.\(key)" }
    private static func attachedKey(_ key: String) -> String { "transcript.codeBlockAttached.\(key)" }
}
