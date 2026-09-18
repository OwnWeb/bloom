import BloomProtocol
import Foundation

/// Whether a Cloud workspace's app can be shown yet, and what to say when it cannot.
///
/// **It said nothing at all, which is the same bug `BrowserLoadFailure` was written for.** Opening
/// the preview pane on a workspace whose setup had not finished exchanged a token, loaded the
/// address, and drew a white rectangle: the machine was up, so nothing failed, and the proxy in
/// front of a port nobody was listening on had nothing to render. A reader cannot tell that from a
/// page still arriving, and the only way to find out was to wait and see.
///
/// **A sentence rather than a spinner, deliberately.** A spinner says "this is coming", which is a
/// promise this pane cannot keep: a workspace created with setup skipped will never start anything
/// on its own, and one whose setup failed will not either. So each state says which state it is in
/// and what would change it, and only the one state that really does fill in by itself says so.
///
/// Here rather than in the pane because these are decisions about what a state means, and a
/// decision taken inside a `View` is a decision nothing can test. See `CloudPreviewPane`.
public enum CloudPreviewReadiness: Equatable, Sendable {
    /// Ask runbloom.app for an address and load it.
    case serving
    /// Do not ask. This is what the pane says instead.
    case waiting(Notice)

    /// What the pane draws in place of the page: a heading, a sentence, and whether pressing
    /// anything would help.
    public struct Notice: Equatable, Sendable {
        public var title: String
        public var message: String
        /// Whether the pane offers Try again. False for the one state that fills in by itself,
        /// where a button to press would suggest the reader has to do something.
        public var invitesRetry: Bool

        public init(title: String, message: String, invitesRetry: Bool) {
            self.title = title
            self.message = message
            self.invitesRetry = invitesRetry
        }
    }

    /// What setup says about whether anything can be serving yet.
    ///
    /// A workspace with no setup record at all is served rather than held: that is a machine which
    /// has not told us about setup, not a machine which is known not to have run it, and refusing
    /// to load on the strength of a fact nobody stated is how a pane comes to be wrong about a
    /// workspace that works.
    ///
    /// **"Setting up" rather than "still setting up".** The word says the same thing in a tone that
    /// implies something has gone on too long, and on a workspace four seconds old it is simply
    /// wrong. It earns its place where there is a real contrast with what somebody expected, which
    /// is why "an agent is still working" stays in the archive sheet and this one lost it.
    public static func of(setup: SetupRecord?) -> CloudPreviewReadiness {
        switch setup?.state {
        case "pending", "running":
            return .waiting(Notice(
                title: "The app is not serving yet",
                message: "This Cloud workspace is setting up. The page appears here on its own when setup has finished.",
                invitesRetry: false
            ))
        case "failed":
            return .waiting(Notice(
                title: "The app is not serving",
                message: "Setup failed, so nothing was started. The setup row at the top of the conversation has the log, and the button to run it again.",
                invitesRetry: true
            ))
        case "skipped":
            return .waiting(Notice(
                title: "The app is not serving",
                message: "This Cloud workspace was created without running setup, so nothing was started. Run setup from the row at the top of the conversation, or start the app in the terminal.",
                invitesRetry: true
            ))
        default:
            return .serving
        }
    }

    /// Setup is out of the way and the address was loaded, and what came back was not the app.
    ///
    /// The machine is up, its proxy answered, and there was nothing behind that proxy to answer
    /// with: a gateway status and an empty body, which is the state this whole type exists for.
    ///
    /// **The port is not named**, though the machine has one and it is in the Runner's environment.
    /// Naming a number in a sentence is a promise about which number it is, and the release that
    /// settles it is not pinned in production yet. It goes in here, in this one sentence, the day
    /// it is.
    public static let nothingAnswered = Notice(
        title: "Nothing is serving the app",
        message: "Setup has finished, but nothing answered on this Cloud workspace. Start the app in its terminal, then reload.",
        invitesRetry: true
    )

    /// Whether what came back counts as "not the app".
    ///
    /// - Parameter status: the HTTP status of the document on screen, or nil where there was no
    ///   HTTP response at all, which is what a page that has not loaded leaves behind.
    ///
    /// A navigation that WebKit reported as failed is not asked about here: it has a sentence of
    /// its own, written against the error, and "the connection was refused" says more than this
    /// does. See `BrowserLoadFailure`.
    ///
    /// **Only the gateway statuses, and 500 is deliberately not one of them.** A 502, 503 or 504 is
    /// the thing in front of the app saying there is nothing behind it; a 500 is the app itself
    /// saying it threw, and its own error page is the most useful thing a developer can be looking
    /// at. Covering a stack trace with a sentence about ports would take away the one page this
    /// pane exists to show. A 404 is the app answering too: a project with no route at `/` is a
    /// project, not a workspace that is not serving.
    public static func isSilent(status: Int?) -> Bool {
        guard let status else { return false }
        return status == 502 || status == 503 || status == 504
    }
}
