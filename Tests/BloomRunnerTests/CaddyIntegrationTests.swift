import AsyncHTTPClient
import Foundation
import HTTPTypes
import Hummingbird
import NIOCore
import Testing
@testable import BloomRunner

/// The rendered Caddyfile, run by a real Caddy in front of a stand-in Bloom Runner and app.
///
/// Only runs where a `caddy` binary is installed, which CI is not; the rules it checks were
/// verified by hand on Linux with a Caddy 2 release, and this is that check kept.
@Suite("The Caddyfile, served by Caddy", .enabled(if: CaddySupervisor.resolveExecutable() != nil))
struct CaddyIntegrationTests {
    static let goodCookie = "__Host-bloom-preview=good"

    struct Machine {
        let caddy: CaddySupervisor
        let server: LocalListener
        let app: LocalListener
        let publicPort: Int
        let http: HTTPClient

        func get(_ path: String, cookie: String? = nil) async throws -> (status: Int, headers: [(String, String)], body: String) {
            var request = HTTPClientRequest(url: "http://127.0.0.1:\(publicPort)\(path)")
            if let cookie { request.headers.add(name: "Cookie", value: cookie) }
            let response = try await http.execute(request, timeout: .seconds(10))
            let body = try await response.body.collect(upTo: 1_048_576)
            return (Int(response.status.code), response.headers.map { ($0.name, $0.value) }, String(buffer: body))
        }

        func stop() async {
            await caddy.stop()
            await server.stop()
            await app.stop()
            try? await http.shutdown()
        }
    }

    static func event(_ text: String) -> ByteBuffer { ByteBuffer(string: "data: \(text)\n\n") }

    func machine() async throws -> Machine {
        let server = try await LocalListener.start { router in
            router.get("/_bloom/health") { _, _ in "bloom-runner" }
            router.get("/_bloom/local/git-credentials") { _, _ in "reached a local route" }
            router.get("/_bloom/preview/check") { request, _ -> Response in
                let cookies = request.headers[values: .cookie].joined(separator: "; ")
                return Response(status: cookies.contains(Self.goodCookie) ? .noContent : .unauthorized,
                                body: .init(byteBuffer: ByteBuffer(string: "refused by the check")))
            }
        }
        let app = try await LocalListener.start { router in
            router.get("/") { request, _ in
                "cookies: " + request.headers[values: .cookie].joined(separator: " | ")
            }
            router.get("/plant") { _, _ -> Response in
                var headers = HTTPFields()
                headers.append(HTTPField(name: .setCookie, value: "__Host-bloom-preview=planted; Path=/; Secure"))
                headers.append(HTTPField(name: .setCookie, value: "theme=dark; Path=/"))
                return Response(status: .ok, headers: headers)
            }
            router.get("/events") { _, _ -> Response in
                Response(status: .ok, headers: [.contentType: "text/event-stream"], body: .init { writer in
                    try await writer.write(Self.event("one"))
                    try await Task.sleep(for: .milliseconds(1_500))
                    try await writer.write(Self.event("two"))
                    try await writer.finish(nil)
                })
            }
        }
        let publicPort = try await FreePort.pick()
        let root = try SetupTestSupport.directory("caddy")
        let layout = MachineLayout(dataDirectory: root, worktree: root, publicPort: publicPort, serverPort: server.port, appPort: app.port)
        let caddy = CaddySupervisor(layout: layout, publicURL: "https://bloom-test.sprites.app", stopGrace: .seconds(2))
        try await caddy.start()
        let http = HTTPClient(eventLoopGroupProvider: .singleton, configuration: .init(redirectConfiguration: .disallow))
        let machine = Machine(caddy: caddy, server: server, app: app, publicPort: publicPort, http: http)
        let listening = await SetupTestSupport.eventually(timeout: .seconds(15)) {
            (try? await machine.get("/_bloom/health"))?.status == 200
        }
        if !listening {
            Issue.record("Caddy did not start: \(SetupTestSupport.read(caddy.logPath))")
        }
        return machine
    }

    @Test("bloom-runner's routes, the local 404 and the preview check")
    func routing() async throws {
        let machine = try await machine()
        let health = try await machine.get("/_bloom/health")
        #expect(health.status == 200 && health.body == "bloom-runner")

        let local = try await machine.get("/_bloom/local/git-credentials")
        #expect(local.status == 404)
        #expect(!local.body.contains("reached"))

        let refused = try await machine.get("/")
        #expect(refused.status == 401)
        #expect(refused.body == "refused by the check")
        await machine.stop()
    }

    @Test("the app gets its own cookies and never the preview cookie")
    func cookieStripped() async throws {
        let machine = try await machine()
        let only = try await machine.get("/", cookie: Self.goodCookie)
        #expect(only.status == 200)
        #expect(!only.body.contains("bloom-preview"))

        let mixed = try await machine.get("/", cookie: "theme=dark; \(Self.goodCookie); laravel_session=xyz")
        #expect(mixed.status == 200)
        #expect(mixed.body == "cookies: theme=dark; laravel_session=xyz")
        await machine.stop()
    }

    @Test("the app cannot set the preview cookie, and its other cookies still arrive")
    func setCookieRefused() async throws {
        let machine = try await machine()
        let planted = try await machine.get("/plant", cookie: Self.goodCookie)
        let cookies = planted.headers.filter { $0.0.lowercased() == "set-cookie" }.map(\.1)
        #expect(cookies.contains("theme=dark; Path=/"))
        #expect(!cookies.contains { $0.contains("planted") })
        await machine.stop()
    }

    @Test("an event stream from the app is not buffered")
    func streaming() async throws {
        let machine = try await machine()
        var request = HTTPClientRequest(url: "http://127.0.0.1:\(machine.publicPort)/events")
        request.headers.add(name: "Cookie", value: Self.goodCookie)
        let response = try await machine.http.execute(request, timeout: .seconds(10))
        var received = ""
        var firstArrivedAt: ContinuousClock.Instant?
        for try await chunk in response.body {
            received += String(buffer: chunk)
            if firstArrivedAt == nil, received.contains("data: one") { firstArrivedAt = ContinuousClock.now }
        }
        let ended = ContinuousClock.now
        #expect(received.contains("data: two"))
        // The gap between the two events rather than the time to the first, which also counted
        // connecting and the forward_auth hop and was over a second on a loaded runner. The app
        // waits 1.5 s between them; a buffered proxy delivers both together.
        let first = try #require(firstArrivedAt)
        #expect(ended - first > .milliseconds(1_000))
        await machine.stop()
    }

    @Test("a request for an app that is not listening says so in plain text")
    func appDown() async throws {
        let machine = try await machine()
        await machine.app.stop()
        let down = try await machine.get("/", cookie: Self.goodCookie)
        #expect(down.status == 502)
        #expect(down.body.hasPrefix("The app is not running."))
        #expect(down.headers.contains { $0.0.lowercased() == "content-type" && $0.1.hasPrefix("text/plain") })
        await machine.stop()
    }
}
