import AsyncHTTPClient
import Foundation

/// Whether a service's `ready = "http:/path"` check has passed yet.
///
/// **Anything below 500 counts.** A Laravel app answering `/` with a redirect to `/login`, or a 404
/// for a path it has not routed, is an app that is up; what is not up is a refused connection or a
/// 502 from a server whose workers have not started. Redirects are not followed, because the
/// target is usually the machine's public URL, which goes out through the Sprite's proxy and back
/// in through Caddy's authentication and would never answer this check.
enum ServiceReadiness {
    /// `http:/up` as a URL on the app's port. Nil for anything that is not an HTTP check.
    static func url(for ready: String, appPort: Int) -> String? {
        guard ready.hasPrefix("http:/") else { return nil }
        let path = String(ready.dropFirst("http:".count))
        return "http://127.0.0.1:\(appPort)\(path)"
    }

    /// Polls until the URL answers or the deadline passes. False on cancellation as well.
    static func wait(for url: String, deadline: Duration, interval: Duration) async -> Bool {
        let client = HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: .init(redirectConfiguration: .disallow, timeout: .init(connect: .seconds(2), read: .seconds(10)))
        )
        let end = ContinuousClock.now + deadline
        var answered = false
        while !Task.isCancelled, ContinuousClock.now < end {
            if await answers(url, client: client) {
                answered = true
                break
            }
            try? await Task.sleep(for: interval)
        }
        try? await client.shutdown()
        return answered
    }

    private static func answers(_ url: String, client: HTTPClient) async -> Bool {
        var request = HTTPClientRequest(url: url)
        request.method = .GET
        guard let response = try? await client.execute(request, timeout: .seconds(10)) else { return false }
        _ = try? await response.body.collect(upTo: 16 * 1_048_576)
        return response.status.code < 500
    }
}
