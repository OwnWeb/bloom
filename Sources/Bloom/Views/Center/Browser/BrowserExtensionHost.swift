import AppKit
import Observation
import WebKit
import BloomCore

/// 1Password's Safari extension, running in Bloom's browser tabs. The decisions that need no
/// WebKit, which appex to load, what Settings says and when an answer still counts, are
/// `BrowserPasswordManager` in the core, with the argument for why this works at all.
///
/// One controller for the app, because the extension is one extension: a controller per tab
/// would be a background page, a lock state and an unlock prompt per tab. It is attached to a
/// web view's configuration when the web view is made, which is the only time WebKit lets it be,
/// so switching the setting on reaches tabs opened afterwards and switching it off unloads the
/// extension from every tab at once.
///
/// **Native messaging cannot reach 1Password's own handler, so Bloom answers one message itself.**
/// In Safari the extension's native messages go to 1Password's appex handler through
/// `NSExtension`, and that lookup finds nothing from any process but Safari's: discovering a Safari
/// web extension takes `com.apple.private.extension-host.safari-extension`, a private entitlement
/// no third party app can hold. Measured on macOS 27 with a bare command line probe, which found
/// zero Safari web extensions and nineteen share extensions. So the extension cannot reach the
/// 1Password app here, and is signed in to the account by itself, with the account's Secret Key,
/// which was confirmed to work under Bloom Dev. The one native question it cannot do without is
/// whether the person is still at the Mac, which its lock monitor asks the moment the vault
/// unlocks and locks it again on any failure, so `sendMessage` below answers that one and refuses
/// the rest. See `BrowserPasswordManager+Native`.
///
/// **Every permission the extension asks for is granted without a prompt.** The switch in Settings
/// is the consent, and its footnote says so: it names one extension, from one vendor, which the
/// user installed themselves, and a prompt per site would be a dialog on every dev server port.
@MainActor
@Observable
final class BrowserExtensionHost: NSObject, WKWebExtensionControllerDelegate {
    static let shared = BrowserExtensionHost()

    /// The switch in Settings. Read from the defaults once and written back through `setEnabled`,
    /// so this is the one reader of the setting and Settings binds to it rather than reading the
    /// key a second time.
    private(set) var isEnabled: Bool

    /// Changed only through `update`, which is what keeps every waiting tab's message in step
    /// with it.
    private var lifecycle = BrowserPasswordManager.Switch()

    var status: BrowserPasswordManager.Status { lifecycle.status }

    /// What a tab waiting on the extension says, as of now. See `BrowserPasswordManager.waitingPage`.
    var waitingPage: BrowserLoadFailure? {
        BrowserPasswordManager.waitingPage(status: status, isOn: isEnabled)
    }

    /// Moved whenever the extension changes its toolbar button, so a toolbar reading `action(for:)`
    /// is redrawn with the new icon or badge. `WKWebExtension.Action` is not observable itself.
    private(set) var actionRevision = 0

    /// A fixed identifier rather than `.default()`, so the extension's storage has a directory of
    /// its own that no other controller in this process could share.
    @ObservationIgnored let controller = WKWebExtensionController(
        configuration: .init(identifier: UUID(uuidString: "6B1F3C52-0D8E-4C1A-9E57-1F0A2B7C4D91")!)
    )
    @ObservationIgnored private var context: WKWebExtensionContext?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private let window = BrowserExtensionWindow()

    /// Open tabs in the order they opened, held weakly: a session that is never stopped, which a
    /// design gallery's is, must not be kept alive by being listed here. Pruned as tabs come and
    /// go rather than as the list is read.
    @ObservationIgnored private var tabs: [WeakTab] = []
    @ObservationIgnored private weak var activeTab: BrowserExtensionTab?

    /// Sessions showing one of the extension's own pages that cannot be served yet: restored at
    /// launch before the extension had loaded, or left open while it was switched off. Each is
    /// given the extension's configuration the moment it loads. See `configuration(forPageAt:)`.
    @ObservationIgnored private var waiting: [WeakSession] = []

    private struct WeakTab {
        weak var tab: BrowserExtensionTab?
    }

    private struct WeakSession {
        weak var session: BrowserSession?
    }

    override private init() {
        isEnabled = UserDefaults.standard.object(forKey: BrowserPasswordManager.settingKey) as? Bool
            ?? BrowserPasswordManager.isOnByDefault
        super.init()
        controller.delegate = self
    }

    // MARK: - The switch

    /// Called by a new web view's session. Attaches the controller when the setting is on, and
    /// starts the first load if nothing has yet. Answers whether it attached, because only a
    /// session that did has a tab to report.
    func attach(to configuration: WKWebViewConfiguration) -> Bool {
        guard isEnabled else { return false }
        configuration.webExtensionController = controller
        startIfNeeded()
        return true
    }

    /// The switch in Settings moved.
    func setEnabled(_ isOn: Bool) {
        isEnabled = isOn
        UserDefaults.standard.set(isOn, forKey: BrowserPasswordManager.settingKey)
        if isOn {
            start()
        } else {
            stop()
        }
    }

    /// Settings has been opened. With the switch on and nothing having asked for the extension
    /// yet this launch, this is what makes the line under it say where things stand.
    func startIfNeeded() {
        if lifecycle.needsStart(isOn: isEnabled) { start() }
    }

    private func start() {
        stop()
        let attempt = update { $0.turnOn() }
        loading = Task { [weak self] in
            let lookup = await BrowserPasswordManager.locate()
            guard let self, let found = self.update({ $0.looked(lookup, attempt: attempt) }) else { return }
            await self.load(found, attempt: attempt)
        }
    }

    /// Unloads the extension from every tab. A tab that was showing one of its own pages is left
    /// on a configuration that serves nothing, so it says why and waits for the switch.
    ///
    /// The tabs are told whether or not anything was loaded. Switching off while still looking
    /// has no context to unload, and returning early there left a tab that had been waiting since
    /// launch saying "Waiting for 1Password" with the switch off.
    private func stop() {
        loading?.cancel()
        loading = nil
        if let context {
            try? controller.unload(context)
            self.context = nil
            actionRevision += 1
        }
        for session in liveTabs.compactMap(\.session) where session.pauseForExtension() {
            enqueue(session)
        }
        update { $0.turnOff() }
    }

    /// The one way the lifecycle changes, so that every tab waiting on the extension is told what
    /// it now says in the same breath.
    @discardableResult
    private func update<Result>(_ change: (inout BrowserPasswordManager.Switch) -> Result) -> Result {
        let result = change(&lifecycle)
        let page = waitingPage
        for session in waiting.compactMap(\.session) {
            session.showWaiting(page)
        }
        return result
    }

    private func load(_ found: BrowserPasswordManager.Installed, attempt: Int) async {
        let url = URL(filePath: found.path, directoryHint: .isDirectory)
        guard let bundle = Bundle(url: url) else {
            update { $0.failed("its bundle at \(found.path) could not be opened.", attempt: attempt) }
            return
        }
        do {
            let webExtension = try await WKWebExtension(appExtensionBundle: bundle)
            // The switch may have moved while WebKit was reading the manifest.
            guard lifecycle.isCurrent(attempt) else { return }
            let context = WKWebExtensionContext(for: webExtension)
            context.baseURL = BrowserPasswordManager.extensionBaseURL
            #if DEBUG
            // Safari's Develop menu can attach to the background page and the popup in a debug
            // build, which is the only way to read what 1Password itself says went wrong: its
            // console reaches the unified log redacted. Never in a release, where it would put a
            // signed in vault's background page in front of any inspector on this Mac.
            context.isInspectable = true
            #endif
            context.uniqueIdentifier = BrowserPasswordManager.runtimeIdentifier(
                bundleIdentifier: bundle.bundleIdentifier ?? found.identifier,
                teamIdentifier: BrowserPasswordManager.signingTeam
            )
            // Granted in full only because `locate` has already checked this appex is signed as
            // 1Password's and refused it otherwise. See `BrowserPasswordManager+Signature`.
            for permission in webExtension.requestedPermissions {
                context.setPermissionStatus(.grantedExplicitly, for: permission)
            }
            for pattern in webExtension.allRequestedMatchPatterns {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }
            try controller.load(context)
            self.context = context
            update { $0.loaded(version: webExtension.displayVersion ?? found.version, attempt: attempt) }
            for tab in liveTabs { controller.didOpenTab(tab) }
            if let activeTab { controller.didActivateTab(activeTab, previousActiveTab: nil) }
            actionRevision += 1
            releaseWaiting(with: context)
        } catch {
            update { $0.failed(error.localizedDescription, attempt: attempt) }
        }
    }

    /// The configuration a web view needs to show one of the extension's own pages, or nil for
    /// any other address, and nil while the extension is not loaded.
    ///
    /// **A browser tab's ordinary configuration cannot show one, and that was the blank page.**
    /// WebKit serves an extension page as a main frame only to a web view whose configuration
    /// names that extension as its required base URL, which is what `webViewConfiguration` sets,
    /// and it answers every other web view with `NSURLErrorResourceUnavailable`, -1008, before a
    /// byte is read. Read in `WebExtensionURLSchemeHandlerCocoa.mm`, and measured in the unified
    /// log as 1Password's welcome page failing its provisional load with exactly that code.
    func configuration(forPageAt address: String) -> WKWebViewConfiguration? {
        guard let context, context.isLoaded, let url = URL(string: address),
              BrowserPasswordManager.isExtensionPage(url)
        else { return nil }
        return context.webViewConfiguration
    }

    /// A session showing one of the extension's pages that has to wait for it to load. One that
    /// asks after the extension has already loaded is given its configuration straight away.
    func waitForExtension(_ session: BrowserSession) {
        if let context, context.isLoaded, let configuration = context.webViewConfiguration {
            session.adoptExtension(configuration: configuration)
            return
        }
        enqueue(session)
        startIfNeeded()
    }

    /// Onto the waiting list, without starting anything. `stop` uses this rather than
    /// `waitForExtension`, because `start` calls `stop` first, and a tab asking to be started from
    /// inside it would start again from inside itself.
    private func enqueue(_ session: BrowserSession) {
        waiting.removeAll { $0.session == nil || $0.session === session }
        waiting.append(WeakSession(session: session))
        session.showWaiting(waitingPage)
    }

    /// Nil from `webViewConfiguration` is a context that is not loaded, which this is only ever
    /// called after loading, so the waiting tabs are left waiting rather than given a guess.
    private func releaseWaiting(with context: WKWebExtensionContext) {
        let sessions = waiting.compactMap(\.session)
        waiting = []
        for session in sessions {
            guard let configuration = context.webViewConfiguration else {
                waitForExtension(session)
                continue
            }
            session.adoptExtension(configuration: configuration)
        }
    }

    // MARK: - Tabs

    private var liveTabs: [BrowserExtensionTab] {
        tabs.compactMap(\.tab)
    }

    func didOpen(_ tab: BrowserExtensionTab) {
        tabs.removeAll { $0.tab == nil }
        tabs.append(WeakTab(tab: tab))
        controller.didOpenTab(tab)
    }

    func didClose(_ tab: BrowserExtensionTab) {
        tabs.removeAll { $0.tab == nil || $0.tab === tab }
        if activeTab === tab { activeTab = nil }
        controller.didCloseTab(tab, windowIsClosing: false)
    }

    /// The tab the reader is looking at, which is what `tabs.query({ active: true })` answers and
    /// what 1Password's popup offers to fill. Bloom has no single selected browser tab, a window
    /// can show several side by side, so the last one put on screen or clicked is it.
    func activate(_ tab: BrowserExtensionTab) {
        guard activeTab !== tab else { return }
        let previous = activeTab
        activeTab = tab
        controller.didActivateTab(tab, previousActiveTab: previous)
    }

    func changed(_ properties: WKWebExtension.TabChangedProperties, on tab: BrowserExtensionTab) {
        controller.didChangeTabProperties(properties, for: tab)
    }

    func tabs(for window: BrowserExtensionWindow) -> [BrowserExtensionTab] { liveTabs }

    func index(of tab: BrowserExtensionTab) -> Int {
        liveTabs.firstIndex { $0 === tab } ?? 0
    }

    func isActive(_ tab: BrowserExtensionTab) -> Bool { activeTab === tab }

    var currentTab: BrowserExtensionTab? { activeTab }

    // MARK: - The toolbar button

    /// The extension's toolbar button for this session's tab, or nil when nothing is loaded.
    func action(for session: BrowserSession) -> BrowserExtensionAction? {
        _ = actionRevision
        guard let context, let tab = session.extensionTab,
              let action = context.action(for: tab)
        else { return nil }
        return BrowserExtensionAction(
            icon: action.icon(for: CGSize(width: 16, height: 16)),
            label: BrowserPasswordManager.actionLabel(action.label),
            badge: action.badgeText,
            isEnabled: action.isEnabled,
            perform: { [weak self, weak tab] in
                guard let self, let tab, let context = self.context else { return }
                self.activate(tab)
                context.performAction(for: tab)
            }
        )
    }

    // MARK: - WKWebExtensionControllerDelegate

    func webExtensionController(
        _ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        [window]
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        window
    }

    /// The extension wants a page of its own, which is what 1Password's toolbar button does when
    /// no account is signed in: it opens its welcome page with `chrome.tabs.create`. It opens as a
    /// Bloom tab in the workspace `BrowserPasswordManager.opener` names.
    ///
    /// **The new tab has to be handed back, and handing back nil was the bug.** 1Password's
    /// callback reads `openerTabId` off what it is given with no check, so a nil tab threw
    /// "null is not an object" inside the extension and the button did nothing at all, every
    /// click. Measured in the unified log under `com.apple.WebKit` `Extensions`.
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        let opener = BrowserPasswordManager.opener(active: activeTab, open: liveTabs)?.session
        guard let url = configuration.url,
              let session = opener?.host.openExtensionTab(url),
              let tab = session.extensionTab
        else {
            completionHandler(nil, BrowserExtensionError.cannotOpenTab)
            return
        }
        activate(tab)
        completionHandler(tab, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        completionHandler(permissions, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        completionHandler(matchPatterns, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        completionHandler(urls, nil)
    }

    /// `browser.runtime.sendNativeMessage`. One message is answered, the lock monitor's question
    /// about whether the Mac is idle, from the system's own idle time; every other one fails, as
    /// it would with no handler at all. The decision is `BrowserPasswordManager.nativeReply`.
    func webExtensionController(
        _ controller: WKWebExtensionController,
        sendMessage message: Any,
        toApplicationWithIdentifier applicationIdentifier: String?,
        for extensionContext: WKWebExtensionContext,
        replyHandler: @escaping (Any?, (any Error)?) -> Void
    ) {
        let fields = message as? [String: Any]
        // Any input at all, which is the one event type CoreGraphics has no case for.
        let anyInput = CGEventType(rawValue: ~0)
        let idle = anyInput.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        } ?? .infinity
        switch BrowserPasswordManager.nativeReply(
            name: fields?["name"] as? String, data: fields?["data"] as? String, idleSeconds: idle
        ) {
        case .reply(let answer): replyHandler(answer, nil)
        case .unsupported: replyHandler(nil, BrowserExtensionError.noNativeMessaging)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        didUpdate action: WKWebExtension.Action,
        forExtensionContext context: WKWebExtensionContext
    ) {
        actionRevision += 1
    }

    /// The popup, which is where 1Password is unlocked and where an item is picked by hand. Where
    /// it is drawn from is `BrowserPasswordManager.popupAnchor`.
    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let popover = action.popupPopover else {
            completionHandler(BrowserExtensionError.cannotShowPopup)
            return
        }
        let session = (action.associatedTab as? BrowserExtensionTab)?.session ?? activeTab?.session
        let button = session?.extensionAnchor
        let page = session?.pageView
        switch BrowserPasswordManager.popupAnchor(
            buttonIsInWindow: button?.window != nil, pageIsInWindow: page?.window != nil
        ) {
        case .button:
            if let button {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        case .pageTop:
            if let page {
                let top = NSRect(x: page.bounds.maxX - 48, y: page.bounds.maxY - 1, width: 32, height: 1)
                popover.show(relativeTo: top, of: page, preferredEdge: .minY)
            }
        case .nowhere:
            completionHandler(BrowserExtensionError.cannotShowPopup)
            return
        }
        completionHandler(nil)
    }
}
