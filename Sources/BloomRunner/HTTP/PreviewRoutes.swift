import BloomCore
import BloomProtocol
import Foundation
import HTTPTypes
import Hummingbird

/// The preview's two paths: entering it with a single-use token, and Caddy asking whether a request
/// may reach the project's app.
///
/// **The preview shares an origin with control, and still cannot reach it.** The machine's URL has
/// one port, so the app and `/_bloom/*` live on the same origin. Control only ever reads a bearer
/// header, never a cookie, so the app's own JavaScript has nothing to borrow; and the preview cookie
/// is HttpOnly, stripped by Caddy before a request reaches the app, and refused if the app tries to
/// set it. See docs/REMOTE-WORKSPACES.md, "Preview".
enum PreviewRoutes {
    static let cookieName = "__Host-bloom-preview"

    static func register(on router: Router<WorkspaceRequestContext>, verifier: TokenVerifier, sessions: PreviewSessions, runtime: WorkspaceRuntime) {
        router.get("/_bloom/preview/enter") { request, _ -> Response in
            guard let raw = request.uri.queryParameters.get("token") else { return notAllowed() }
            let token: WorkspaceToken
            do {
                token = try await verifier.verify(String(raw), as: .preview)
            } catch {
                return notAllowed()
            }
            // The verifier grants a preview token nothing but `preview`, and this says so here too,
            // so the route does not rest on that alone.
            guard token.abilities.contains("preview") else { return notAllowed() }
            // Eight hours for a person, one for a share link, which is somebody runbloom.app let in
            // without an account.
            let lifetime: TimeInterval = token.isShare ? 3_600 : 8 * 3_600
            let cookie = await sessions.create(subject: token.subject, lifetime: lifetime)
            var headers = HTTPFields()
            headers[.setCookie] = "\(cookieName)=\(cookie); Path=/; Max-Age=\(Int(lifetime)); HttpOnly; Secure; SameSite=Lax"
            headers[.location] = "/"
            headers[.cacheControl] = "no-store"
            return Response(status: .seeOther, headers: headers)
        }

        // Caddy's forward_auth: 2xx lets the request through to the app, anything else is sent back
        // to the browser as it is.
        router.get("/_bloom/preview/check") { request, _ -> Response in
            guard let cookie = Self.cookie(in: request), let subject = await sessions.subject(for: cookie) else {
                return notAllowed()
            }
            if !subject.hasPrefix("share:") {
                await runtime.noteHumanInput(from: MessageAuthor(userID: subject, name: ""))
            }
            return Response(status: .noContent)
        }
    }

    static func cookie(in request: Request) -> String? {
        for header in request.headers[values: .cookie] {
            for pair in header.split(separator: ";") {
                let parts = pair.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
                if parts.count == 2, parts[0] == cookieName { return String(parts[1]) }
            }
        }
        return nil
    }

    private static func notAllowed() -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "text/plain; charset=utf-8"
        headers[.cacheControl] = "no-store"
        let text = "This preview has to be opened from Bloom.\n"
        return Response(status: .unauthorized, headers: headers, body: .init(byteBuffer: ByteBuffer(string: text)))
    }
}
