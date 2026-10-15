import Foundation

/// 1Password in the browser pane, by loading the Safari extension the user already has.
///
/// **The extension is 1Password's own and nothing of it is copied here.** Since macOS 15.4 WebKit
/// can run a Safari web extension inside an app's own `WKWebView` (`WKWebExtensionController`), and
/// `WKWebExtension(appExtensionBundle:)` takes the very `.appex` Safari runs. 1Password ships that
/// appex inside "1Password for Safari", from the App Store, rather than inside 1Password.app, so
/// that is what has to be installed.
///
/// **It cannot reach the 1Password app, and that was measured rather than assumed.** In Safari the
/// extension talks to the app through `browser.runtime.sendNativeMessage`, which WebKit hands to
/// the appex's own handler through `NSExtension` (`WebExtensionContextAPIRuntimeCocoa.mm`). That
/// lookup returns nothing outside Safari, because finding a Safari web extension needs a private
/// entitlement Safari has and no third party app can. So the extension runs on its own: the
/// toolbar button opens 1Password's welcome page, and the account is signed in to there, with the
/// Secret Key, rather than unlocked by the app. Whether 1Password lets an account sign in this way
/// outside Safari has not been confirmed. `BrowserExtensionHost` has the detail.
///
/// The setting is off by default and says what it needs.
public enum BrowserPasswordManager {
    public static let settingKey = "browser.usesOnePassword"
    public static let isOnByDefault = false

    /// The extension point every Safari web extension registers under, which is what `pluginkit`
    /// is asked about.
    public static let extensionPoint = "com.apple.Safari.web-extension"

    /// One line of `pluginkit -m -v`: which appex, at what version, where on disk.
    public struct Installed: Equatable, Sendable {
        public let identifier: String
        public let version: String
        public let path: String

        public init(identifier: String, version: String, path: String) {
            self.identifier = identifier
            self.version = version
            self.path = path
        }
    }

    /// Every Safari web extension `pluginkit` reported.
    ///
    /// A line is an election mark, spaces, `identifier(version)`, then tab separated UUID,
    /// timestamp and path: `+    com.example.ext(1.2)\t4339EF...\t2026-10-02 00:06:10 +0000\t/Ap...`.
    /// The mark is `+`, `-`, `!`, `=` or a space, and none of them matters here: whether Safari
    /// has the extension switched on is Safari's business, and 1Password's own app is what decides
    /// whether a caller is answered. The path is taken as the last field rather than the fourth,
    /// so a pluginkit that adds a column in the middle still yields the right one.
    public static func installed(fromPluginKit output: String) -> [Installed] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2,
                  let path = fields.last.map({ $0.trimmingCharacters(in: .whitespaces) }),
                  path.hasPrefix("/")
            else { return nil }

            let head = fields[0].drop { "+-!=? ".contains($0) }.trimmingCharacters(in: .whitespaces)
            guard !head.isEmpty else { return nil }
            guard head.hasSuffix(")"), let open = head.lastIndex(of: "(") else {
                return Installed(identifier: head, version: "", path: path)
            }
            let identifier = String(head[..<open])
            let version = String(head[head.index(after: open)..<head.index(before: head.endIndex)])
            guard !identifier.isEmpty else { return nil }
            return Installed(identifier: identifier, version: version, path: path)
        }
    }

    /// 1Password's appex out of everything installed, or nil.
    ///
    /// **By its exact identifier and nothing looser.** This once took any `com.1password.` or
    /// `com.agilebits.` prefix, or any appex inside an app named 1Password, and every one of those
    /// is a string another developer can register: the extension picked here is granted every
    /// permission it asks for on every site, so a match on a name was a way for some other
    /// extension to read every page in Bloom while Settings called it 1Password. A match here is
    /// still only a candidate. `signature(ofBundleAt:)` decides whether it is 1Password's.
    ///
    /// An appex inside `/Applications` beats one anywhere else, so a copy sitting in a Downloads
    /// folder does not win over the installed one.
    public static func onePassword(in installed: [Installed]) -> Installed? {
        let matches = installed.filter { $0.identifier == extensionIdentifier }
        return matches.first { $0.path.hasPrefix("/Applications/") } ?? matches.first
    }

    /// What asking `pluginkit` came to.
    ///
    /// **Not being able to ask is not the same as an answer of no**, and it was first reported as
    /// one: a pluginkit that failed came back as nil and Settings told somebody who had
    /// 1Password for Safari installed to go and install it from the App Store.
    public enum Lookup: Equatable, Sendable {
        case found(Installed)
        case notInstalled
        case unavailable(String)
        /// An appex under 1Password's identifier whose code signature is not 1Password's. Nothing
        /// of it is loaded and nothing is granted to it.
        case untrusted(Installed, String)
    }

    /// What pluginkit's exit status and output say, without running it.
    public static func lookup(status: Int32, output: String, errors: String = "") -> Lookup {
        guard status == 0 else {
            let said = errors.trimmingCharacters(in: .whitespacesAndNewlines)
            return .unavailable(said.isEmpty ? "pluginkit exited with status \(status)" : said)
        }
        return onePassword(in: installed(fromPluginKit: output)).map(Lookup.found) ?? .notInstalled
    }

    /// A found appex, kept only if its signature is 1Password's. `check` is
    /// `signature(ofBundleAt:)`, passed in so the decision can be tested without a real bundle.
    public static func verified(_ lookup: Lookup, check: (URL) -> Signature) -> Lookup {
        guard case .found(let installed) = lookup else { return lookup }
        switch check(URL(filePath: installed.path, directoryHint: .isDirectory)) {
        case .trusted: return lookup
        case .untrusted(let reason): return .untrusted(installed, reason)
        }
    }

    /// Asks `pluginkit` where 1Password's Safari extension is, and checks the answer is signed by
    /// 1Password before saying it was found.
    ///
    /// Here rather than in the host because checking a signature hashes every file in the appex,
    /// and this runs off the main actor where the host does not. `@concurrent` says so outright,
    /// rather than leaning on a default that a future language setting would change.
    @concurrent
    public static func locate() async -> Lookup {
        do {
            let result = try await Shell.run(
                "/usr/bin/pluginkit", ["-m", "-v", "-p", extensionPoint], timeout: .seconds(30)
            )
            let lookup = lookup(status: result.status, output: result.stdout, errors: result.stderr)
            return verified(lookup, check: signature(ofBundleAt:))
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    /// What `browser.runtime.id` should say: Safari's own spelling, the bundle identifier with the
    /// team in brackets after it.
    ///
    /// WebKit's default is a fresh UUID per load, which an extension that stores anything against
    /// its own identifier would see change on every launch. Safari's form is stable and is what
    /// 1Password's code has only ever been run under. Without a team it is the bundle identifier
    /// alone, which is still stable.
    public static func runtimeIdentifier(bundleIdentifier: String, teamIdentifier: String?) -> String {
        guard let teamIdentifier, !teamIdentifier.isEmpty else { return bundleIdentifier }
        return "\(bundleIdentifier) (\(teamIdentifier))"
    }

    /// Where the extension's own pages live, fixed rather than WebKit's default.
    ///
    /// **The default is a fresh host on every load**, and the host is the origin of every page the
    /// extension draws, so everything 1Password keeps in its pages' local storage and IndexedDB,
    /// which is the account it was signed in to, belonged to an origin that was gone by the next
    /// launch. A tab left open on one of its pages would also come back to an address naming
    /// nothing. Any fixed host will do; this one is a UUID so it can never be a real site's.
    public static let extensionBaseURL = URL(string: "webkit-extension://3f7c9a2e-58b1-4d06-a1e4-6c2d90b7f514/")!

    /// Whether the extension may have this address opened as a Bloom tab.
    ///
    /// Its own pages, which is what 1Password opens for its welcome and sign in screens, and
    /// ordinary web addresses, which is a site it is about to fill. Not any other scheme: the
    /// gate a page's `window.open` goes through, `BrowserAddress.shows`, refuses every one of
    /// those for good reasons, and this door is only wider by the extension's own origin.
    public static func mayOpenTab(_ url: URL, extensionBase: URL = extensionBaseURL) -> Bool {
        BrowserAddress.shows(url) || isExtensionPage(url, extensionBase: extensionBase)
    }

    /// Whether this is one of the extension's own pages, which a web view can only show if it was
    /// made with the extension's configuration rather than a browser tab's. See
    /// `BrowserExtensionHost.configuration(forPageAt:)`.
    public static func isExtensionPage(_ url: URL, extensionBase: URL = extensionBaseURL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased() else {
            return false
        }
        return scheme == extensionBase.scheme?.lowercased() && host == extensionBase.host()?.lowercased()
    }

    /// Why an agent may not drive browser `number`, or what it brought back may not be handed
    /// over, or nil when it may.
    ///
    /// **The extension's own pages are the password manager itself, not a site.** They are where
    /// the Secret Key is typed and, once signed in, where the vault is listed. Every other page a
    /// `browser_` tool can reach is one the reader opened on the web, which the head of
    /// `BrowserPaneCommand` argues for; these are not that, so no tool reads, types into or
    /// photographs one. `browser_read` still answers, because it reports the address and title a
    /// tab already shows in the strip and nothing out of the page.
    ///
    /// **Asked twice: before a tool runs, and again once it has.** A screenshot, the page's text,
    /// its outline or its requests are each a wait on WebKit, and the tab can move while that wait
    /// is in flight. The first version asked only before, so a tab that went from a site to one of
    /// these pages during a read handed over whatever the read found there. `sawProtectedPage` is
    /// the tab having arrived on one at any point during the call, which catches a visit that is
    /// already over by the time the answer comes back as well as one that is not.
    public static func agentRefusal(
        address: String, sawProtectedPage: Bool = false, browser number: Int
    ) -> String? {
        if sawProtectedPage {
            return "Browser \(number) went to one of 1Password's own pages while Bloom was working "
                + "on it, so nothing it read is handed over. Call the tool again once it is back on "
                + "a page of your own."
        }
        guard let url = URL(string: address), isExtensionPage(url) else { return nil }
        return "Browser \(number) is showing one of 1Password's own pages, which hold its sign in "
            + "and its vault. Bloom does not let an agent read, type into or photograph them."
    }
}
