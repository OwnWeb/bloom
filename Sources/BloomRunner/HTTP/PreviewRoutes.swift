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

    /// What to say about ports on the page somebody sees when the preview is empty.
    ///
    /// Nothing when the app's port is listening, because then the port is not the problem and a
    /// paragraph about it is noise over whatever is. The variable is named rather than the number
    /// alone: every script this machine runs is handed `BLOOM_APP_PORT`, so a project that reads it
    /// cannot be on the wrong port, and a project that hard-codes one can be told which to change.
    static func portAdvice(appPort: Int, listening: [Int], reserved: [Int]) -> [String] {
        guard !listening.contains(appPort) else { return [] }
        var lines = ["", "The preview reads port \(appPort), and nothing is listening there."]
        // Bloom's own ports are not an answer to "where is your app", and offering them as one
        // would send somebody to proxy the preview at itself.
        let others = listening.filter { $0 != appPort && !reserved.contains($0) }
        if others.isEmpty {
            lines.append("Nothing else is listening either, so the app has not started yet.")
        } else {
            lines.append("Something is listening on \(others.map(String.init).joined(separator: ", ")).")
            lines.append("Serve the app on \(appPort), which every script is handed as BLOOM_APP_PORT.")
        }
        return lines
    }

    // The ports Bloom holds are `MachineLayout.reservedPorts` and are passed in. They used to be a
    // second copy of the list here, which was the same fact written twice: both of Bloom's ports
    // can be moved by the environment, so a machine with either overridden would have had this page
    // offering Bloom's own port as somewhere the project's app might be listening.

    static func register(on router: Router<WorkspaceRequestContext>, verifier: TokenVerifier, sessions: PreviewSessions,
                         runtime: WorkspaceRuntime, services: @escaping @Sendable () async -> [ServiceSupervisor.Status] = { [] },
                         appPort: Int = 3000,
                         reservedPorts: [Int] = [],
                         listening: @escaping @Sendable () -> [Int] = { ListeningPorts.current() }) {
        // What Caddy shows instead of its own 502 when the project's app is not listening. A person
        // who opens the preview and sees a bare gateway error has no way to find out that the app
        // crashed at boot; the supervisor knows, so it says so. Only somebody who got past the
        // preview check reaches it, and it names nothing but the services from the project's own
        // settings file and how they ended.
        router.get("/_bloom/preview/unavailable") { request, _ -> Response in
            var lines = ["The app in this Bloom Cloud workspace is not answering yet."]
            // The services are named only to somebody the preview let in. Caddy reaches this with
            // the original request, but a request straight to this path has no cookie and is told
            // nothing about the project.
            guard let cookie = Self.cookie(in: request), await sessions.subject(for: cookie) != nil else {
                return Self.plain(lines.joined(separator: "\n") + "\n")
            }
            // The port contract, said out loud, because it is the likeliest reason to be here and
            // the one nothing else states. A project that serves on its own port gets a preview
            // that says the app is not answering, which is true and leaves somebody to deduce that
            // there is an agreed port at all: one workspace served on 8091 while the preview read
            // 3000, and an agent built a second proxy to bridge them.
            lines.append(contentsOf: portAdvice(appPort: appPort, listening: listening(), reserved: reservedPorts))
            let statuses = await services()
            if statuses.isEmpty {
                lines.append("No services are configured in .bloom/settings.toml, so nothing was started for it.")
            } else {
                lines.append("")
                for status in statuses {
                    let restarts = status.restarts > 0 ? " after \(status.restarts) restart\(status.restarts == 1 ? "" : "s")" : ""
                    lines.append("\(status.name): \(status.state.rawValue)\(restarts). \(status.message ?? "")".trimmingCharacters(in: .whitespaces))
                }
            }
            return Self.plain(lines.joined(separator: "\n") + "\n")
        }

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

    private static func plain(_ text: String) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "text/plain; charset=utf-8"
        headers[.cacheControl] = "no-store"
        return Response(status: .badGateway, headers: headers, body: .init(byteBuffer: ByteBuffer(string: text)))
    }
}
