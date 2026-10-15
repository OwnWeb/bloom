import Foundation

/// The setting's lifecycle: off, looking, and how looking ended, with stale answers dropped.
///
/// Out of `BrowserExtensionHost`, which holds WebKit and so cannot be tested, because the bug it
/// had was here. Looking takes a subprocess and then a manifest read, both asynchronous, and the
/// switch can move while either is in flight: a load that threw after the switch had been turned
/// off and on again wrote `.failed` over the newer attempt. Every turn of the switch now starts a
/// numbered attempt, and an answer carrying an older number changes nothing.
extension BrowserPasswordManager {
    /// Where loading has got to, for the line under the switch in Settings.
    public enum Status: Equatable, Sendable {
        case off
        case looking
        case notInstalled
        /// pluginkit could not be asked, which says nothing about whether 1Password is installed.
        case cannotLook(String)
        case failed(String)
        case ready(version: String)

        /// The line under the switch. The switch's own position wins over the status, so turning
        /// it off shows what it does rather than the last thing the extension did.
        public func footnote(isOn: Bool) -> String {
            guard isOn else { return Self.off.footnote }
            return footnote
        }

        var footnote: String {
            switch self {
            case .off:
                "Loads the 1Password for Safari extension, from the App Store, into browser tabs, "
                    + "and grants it every permission it asks for, on every site, without asking "
                    + "again. macOS only lets Safari connect it to the 1Password app, so here you "
                    + "sign in to your account inside the extension, with your Secret Key. Switching "
                    + "this off leaves 1Password's own pages unable to load until it is back on."
            case .looking:
                "Looking for 1Password for Safari."
            case .notInstalled:
                "1Password for Safari is not installed. Install it from the App Store, then switch "
                    + "this off and on again."
            case .cannotLook(let reason):
                "Bloom could not ask macOS which Safari extensions are installed (\(reason)). "
                    + "Switch this off and on again to try once more."
            case .failed(let reason):
                "1Password for Safari was found but would not load: \(reason)"
            case .ready(let version):
                (version.isEmpty ? "1Password is loaded." : "1Password \(version) is loaded.")
                    + " A browser tab that was already open when this was switched on has to be "
                    + "closed and opened again."
            }
        }
    }

    /// The switch and where its current attempt has got to.
    public struct Switch: Equatable, Sendable {
        public private(set) var status = Status.off
        /// Which attempt is current. Moved by every turn of the switch, in either direction.
        public private(set) var attempt = 0

        public init() {}

        /// Whether anything has to start: on, and nothing tried yet since it was last off. A
        /// failed or missing extension is not retried by every tab that opens, because each try
        /// is a subprocess; switching off and on again is the retry.
        public func needsStart(isOn: Bool) -> Bool {
            isOn && status == .off
        }

        /// Whether an answer for `attempt` still counts.
        public func isCurrent(_ attempt: Int) -> Bool {
            attempt == self.attempt && status == .looking
        }

        /// Starts looking, and answers with the number the answers must carry.
        public mutating func turnOn() -> Int {
            attempt += 1
            status = .looking
            return attempt
        }

        public mutating func turnOff() {
            attempt += 1
            status = .off
        }

        /// pluginkit answered. Returns the extension to load, or nil when there is nothing to load
        /// or the answer is for an attempt that has since been replaced.
        public mutating func looked(_ lookup: Lookup, attempt: Int) -> Installed? {
            guard isCurrent(attempt) else { return nil }
            switch lookup {
            case .found(let installed):
                return installed
            case .notInstalled:
                status = .notInstalled
            case .unavailable(let reason):
                status = .cannotLook(reason)
            case .untrusted(_, let reason):
                status = .failed(reason)
            }
            return nil
        }

        /// The extension loaded. False for a stale attempt, which the caller has to undo.
        @discardableResult
        public mutating func loaded(version: String, attempt: Int) -> Bool {
            guard isCurrent(attempt) else { return false }
            status = .ready(version: version)
            return true
        }

        public mutating func failed(_ reason: String, attempt: Int) {
            guard isCurrent(attempt) else { return }
            status = .failed(reason)
        }
    }
}
