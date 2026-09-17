import HTTPTypes
import Hummingbird

/// Cross-origin access to `/_bloom/v1/*` for the web origins runbloom.app pinned at bootstrap.
///
/// **Never with credentials.** Control authenticates with a bearer header, which a browser only
/// sends when the page's own code attaches it, so a site that is not on the list cannot make a
/// signed-in person's browser act here, and allowing credentials would buy nothing but the risk.
/// The preview paths send no CORS headers of their own: what the project's app does is its business.
///
/// A responder around the router rather than router middleware, because a preflight is an
/// `OPTIONS` request for a path that has no `OPTIONS` route, and router middleware only runs for a
/// route that matched.
struct CORSResponder<Wrapped: HTTPResponder>: HTTPResponder where Wrapped.Context == WorkspaceRequestContext {
    typealias Context = WorkspaceRequestContext

    let wrapped: Wrapped
    let allowedOrigins: Set<String>

    func respond(to request: Request, context: Context) async throws -> Response {
        guard request.uri.path.hasPrefix("/_bloom/v1/") else { return try await wrapped.respond(to: request, context: context) }
        let origin = request.headers[.origin]
        let allowed = origin.map { allowedOrigins.contains($0) } ?? false
        if request.method == .options {
            guard allowed, let origin else { return Response(status: .forbidden) }
            var headers = HTTPFields()
            headers[.accessControlAllowOrigin] = origin
            headers[.accessControlAllowMethods] = "GET, POST, OPTIONS"
            headers[.accessControlAllowHeaders] = "Authorization, Content-Type, Last-Event-ID"
            headers[.accessControlMaxAge] = "600"
            headers[.vary] = "Origin"
            return Response(status: .noContent, headers: headers)
        }
        var response = try await wrapped.respond(to: request, context: context)
        if allowed, let origin {
            response.headers[.accessControlAllowOrigin] = origin
            response.headers[.accessControlExposeHeaders] = EventStreamRoute.streamIDHeader.rawName
            response.headers[.vary] = "Origin"
        }
        return response
    }
}
