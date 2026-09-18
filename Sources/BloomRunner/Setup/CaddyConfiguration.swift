import Foundation

/// The Caddyfile in front of the machine's one URL port.
///
/// **Why a proxy at all, since it is asked every time somebody meets this.** A Sprite has one URL
/// and it routes HTTPS to one HTTP port: no second hostname, no per-port subdomain, no custom
/// domain, and its authentication is all or nothing, private to the organisation or public to
/// anyone with the link. Checked in the provider's own documentation and its CLI on 18 September
/// 2026, and the answer decided this: **control and the preview cannot have separate origins, so
/// something must split the one port**. Without a proxy the URL serves either Bloom Runner, and
/// there is no preview, or the project's app, and no client can reach the workspace at all.
/// The costs are real and were accepted with it: a second supervised process, a binary in the
/// release, and the four rules below, every one of which exists only because the origins are
/// shared. If a future provider offers a second port, this whole file and those four rules can go.
///
/// The machine's URL routes to a single port, so control and the preview cannot have separate
/// origins. Caddy sits on that port and splits it: `/_bloom/*` to Bloom Runner, everything else to
/// the project's app behind the preview cookie. Caddy rather than a proxy in Swift, because
/// streaming, WebSocket upgrades for Vite and Reverb, and header rewriting are what it is for. See
/// docs/REMOTE-WORKSPACES.md, "Preview".
///
/// The rules that make one origin safe to share, each of which the integration test checks
/// against a real Caddy:
///
/// - `/_bloom/local/*` is a 404 from outside. Those routes (the git credential helper's) are for
///   processes on the machine, which reach Bloom Runner's loopback port directly.
/// - The preview cookie is removed from `Cookie` before the app sees the request, so an app that
///   logs its headers, or its JavaScript reading a reflected header, has nothing to replay.
/// - A `Set-Cookie` from the app naming the preview cookie is emptied, so the app cannot plant a
///   cookie of its choosing in place of the one Bloom Runner issued. The header is blanked rather
///   than removed because Caddy's header rewriting works per value, and an empty `Set-Cookie`
///   is ignored by browsers (RFC 6265, 5.2).
/// - Streaming is never buffered (`flush_interval -1`), for the event stream and for an app's own
///   server-sent events alike.
/// - A 502 from the app is answered by Bloom Runner rather than by Caddy, so somebody looking at a
///   preview that shows nothing is told what the project's services are doing.
///
/// Automatic HTTPS and the admin endpoint are off: the Sprite's proxy terminates TLS, and an admin
/// API on a machine that runs other people's code is a way to rewrite these rules from inside.
public struct CaddyConfiguration: Sendable, Hashable {
    public var publicPort: Int
    public var serverPort: Int
    public var appPort: Int
    public var accessLogPath: String
    /// What the app is told the browser used, since Caddy itself only ever sees plain HTTP from
    /// the Sprite's proxy. Laravel builds `https://` links from it.
    public var forwardedProto: String

    public init(publicPort: Int, serverPort: Int, appPort: Int, accessLogPath: String, forwardedProto: String = "https") {
        self.publicPort = publicPort
        self.serverPort = serverPort
        self.appPort = appPort
        self.accessLogPath = accessLogPath
        self.forwardedProto = forwardedProto
    }

    public init(layout: MachineLayout, publicURL: String) {
        let scheme = URL(string: publicURL)?.scheme?.lowercased()
        self.init(
            publicPort: layout.publicPort, serverPort: layout.serverPort, appPort: layout.appPort,
            accessLogPath: layout.dataDirectory + "/caddy/access.log",
            forwardedProto: scheme == "http" ? "http" : "https"
        )
    }

    public static var cookieName: String { PreviewRoutes.cookieName }

    /// Removes the cookie from a `Cookie` header wherever it sits in the list, and with it the
    /// separator that would otherwise be left dangling. Two alternatives because RE2 has no
    /// lookbehind: first in the list, and after a `;`.
    static var cookieStripPattern: String {
        let name = NSRegularExpression.escapedPattern(for: cookieName)
        return #"^\s*"# + name + #"=[^;]*(?:;\s*|$)|;\s*"# + name + #"=[^;]*"#
    }

    /// A whole `Set-Cookie` value that sets the cookie. Case-insensitive, because browsers apply
    /// the `__Host-` prefix rules to the name case-insensitively.
    static var setCookiePattern: String {
        #"(?i)^\s*"# + NSRegularExpression.escapedPattern(for: cookieName) + #"\s*=.*$"#
    }

    public func render() -> String {
        """
        # Written by Bloom Runner at every start, so an edit here does not survive a restart.
        {
        \tadmin off
        \tauto_https off
        \tpersist_config off
        }

        :\(publicPort) {
        \tlog {
        \t\toutput file \(Self.quoted(accessLogPath)) {
        \t\t\troll_size 10MiB
        \t\t\troll_keep 2
        \t\t}
        \t}

        \t@local path /_bloom/local /_bloom/local/*
        \thandle @local {
        \t\trespond 404
        \t}

        \thandle /_bloom/* {
        \t\treverse_proxy 127.0.0.1:\(serverPort) {
        \t\t\tflush_interval -1
        \t\t}
        \t}

        \thandle {
        \t\troute {
        \t\t\tforward_auth 127.0.0.1:\(serverPort) {
        \t\t\t\turi /_bloom/preview/check
        \t\t\t}
        \t\t\trequest_header Cookie `\(Self.cookieStripPattern)` ""
        \t\t\treverse_proxy 127.0.0.1:\(appPort) {
        \t\t\t\tflush_interval -1
        \t\t\t\theader_up X-Forwarded-Proto \(forwardedProto)
        \t\t\t\theader_down Set-Cookie `\(Self.setCookiePattern)` ""
        \t\t\t}
        \t\t}
        \t}

        \thandle_errors {
        \t\t@appDown expression `{http.error.status_code} == 502 && !path('/_bloom/*')`
        \t\thandle @appDown {
        \t\t\trewrite * /_bloom/preview/unavailable
        \t\t\treverse_proxy 127.0.0.1:\(serverPort)
        \t\t}
        \t}
        }

        """
    }

    /// A Caddyfile token in double quotes, which is how a path with a space in it stays one token.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
