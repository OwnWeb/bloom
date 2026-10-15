import Foundation

/// The one native message Bloom answers for 1Password, which is whether the person at this Mac is
/// still there.
///
/// **Without an answer to it the vault locked the moment it unlocked, and that was the popup
/// asking for the password again and again.** The Safari build's lock monitor sends
/// `{name: "query-active-status", data: {maximumIdleTimeInSeconds}}` to its own native handler,
/// treats every reply but `"active"` as idle, and treats a failed message as `"locked"`. Read in
/// 1Password's `safari-macos-lock-monitor.ts`, and seen in its background page's console under
/// Bloom Dev: "Unable to communicate with native app, locking", then "Locked", in the same second
/// as "b5x-unlocked".
///
/// The native handler cannot be reached from here (`BrowserExtensionHost` says why), so Bloom gives
/// the answer it would: the system's own idle time against the auto-lock time 1Password asked
/// about. 1Password's auto-lock therefore still locks when the Mac has been left alone for as long
/// as its setting says. Every other native message is refused, as it was before, because Bloom does
/// not know what the rest of them mean and an answer it made up would be worse than none.
extension BrowserPasswordManager {
    /// What the lock monitor calls the question.
    public static let activeStatusMessage = "query-active-status"

    public enum NativeReply: Equatable, Sendable {
        /// Hand this string back to the extension as the reply.
        case reply(String)
        /// Not a message Bloom answers. The extension is told native messaging is unavailable.
        case unsupported
    }

    /// The reply to the native message `name` carrying `data`, with the Mac idle for
    /// `idleSeconds`.
    ///
    /// Anything that cannot be read is idle rather than active, so a question Bloom misunderstands
    /// locks the vault instead of keeping it open.
    public static func nativeReply(name: String?, data: String?, idleSeconds: Double) -> NativeReply {
        guard name == activeStatusMessage else { return .unsupported }
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)),
              let fields = object as? [String: Any],
              let limit = (fields["maximumIdleTimeInSeconds"] as? NSNumber)?.doubleValue,
              limit > 0, idleSeconds.isFinite, idleSeconds >= 0
        else { return .reply("idle") }
        return .reply(idleSeconds < limit ? "active" : "idle")
    }
}
