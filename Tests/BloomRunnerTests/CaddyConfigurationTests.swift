import Foundation
import Testing
@testable import BloomCore
@testable import BloomRunner

@Suite("The Caddyfile in front of the machine")
struct CaddyConfigurationTests {
    static let configuration = CaddyConfiguration(
        layout: MachineLayout(dataDirectory: "/home/sprite/.bloom", worktree: "/home/sprite/workspace"),
        publicURL: "https://bloom-01k5.sprites.app"
    )

    /// **The reserved ports are the layout's, not a copy.** Both of Bloom's own can be moved by the
    /// environment, and a second list here would have sent somebody looking for their app on the
    /// machine's own server.
    @Test("a machine with Bloom's ports moved does not offer the moved ones as the app")
    func movedReservedPorts() {
        let lines = PreviewRoutes.portAdvice(appPort: 3000, listening: [9090, 9091], reserved: [9090, 9091])

        #expect(lines.contains { $0.contains("has not started yet") })
        #expect(!lines.contains { $0.contains("9090") })
    }

    @Test("HTTPS and the admin endpoint are off, and it listens on the URL port")
    func globalOptions() {
        let text = Self.configuration.render()
        #expect(text.contains("\tadmin off\n"))
        #expect(text.contains("\t\t\tread_header 10s\n"), "a request's headers arrive within ten seconds or it is dropped")
        #expect(!text.contains("read_body") && !text.contains("\twrite "), "an upload and a stream are never cut short")
        #expect(text.contains("\tauto_https off\n"))
        #expect(text.contains("\n:8080 {\n"))
        #expect(text.contains(#"output file "/home/sprite/.bloom/caddy/access.log""#))
    }

    @Test("local routes are a 404, and the rest of /_bloom reaches bloom-runner unbuffered")
    func bloomRoutes() {
        let text = Self.configuration.render()
        #expect(text.contains("@local path /_bloom/local /_bloom/local/*\n\thandle @local {\n\t\trespond 404\n\t}"))
        #expect(text.contains("handle /_bloom/* {\n\t\treverse_proxy 127.0.0.1:8081 {\n\t\t\tflush_interval -1\n\t\t}"))
    }

    @Test("the app sits behind the preview check, in that order, with the cookie handled both ways")
    func appRoute() throws {
        let text = Self.configuration.render()
        let auth = try #require(text.range(of: "forward_auth 127.0.0.1:8081 {\n\t\t\t\turi /_bloom/preview/check"))
        let strip = try #require(text.range(of: "request_header Cookie"))
        let proxy = try #require(text.range(of: "reverse_proxy 127.0.0.1:3000 {"))
        #expect(auth.lowerBound < strip.lowerBound && strip.lowerBound < proxy.lowerBound)
        #expect(text.contains("header_down Set-Cookie"))
        #expect(text.contains("header_up X-Forwarded-Proto https"))
        #expect(text.contains("{http.error.status_code} == 502 && !path('/_bloom/*')"))
        #expect(text.contains("rewrite * /_bloom/preview/unavailable"))
    }

    @Test("the cookie pattern removes the preview cookie from anywhere in the header and nothing else")
    func cookiePattern() throws {
        // NSRegularExpression and RE2 agree on everything this pattern uses.
        let expression = try NSRegularExpression(pattern: CaddyConfiguration.cookieStripPattern)
        func strip(_ header: String) -> String {
            expression.stringByReplacingMatches(in: header, range: NSRange(header.startIndex..., in: header), withTemplate: "")
        }
        #expect(strip("__Host-bloom-preview=abc") == "")
        #expect(strip("__Host-bloom-preview=abc; theme=dark") == "theme=dark")
        #expect(strip("theme=dark; __Host-bloom-preview=abc") == "theme=dark")
        #expect(strip("a=1; __Host-bloom-preview=abc; b=2") == "a=1; b=2")
        #expect(strip("a=1; x__Host-bloom-preview=abc") == "a=1; x__Host-bloom-preview=abc")
        #expect(strip("laravel_session=xyz") == "laravel_session=xyz")
    }

    @Test("the Set-Cookie pattern matches the preview cookie only")
    func setCookiePattern() throws {
        let expression = try NSRegularExpression(pattern: CaddyConfiguration.setCookiePattern.replacingOccurrences(of: "(?i)", with: ""),
                                                 options: [.caseInsensitive])
        func matches(_ value: String) -> Bool {
            expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
        }
        #expect(matches("__Host-bloom-preview=planted; Path=/; Secure"))
        #expect(matches("__host-BLOOM-preview=planted"))
        #expect(!matches("laravel_session=xyz; Path=/"))
        #expect(!matches("other=__Host-bloom-preview=x"))
    }

    @Test("ports and the forwarded scheme follow the layout and the URL")
    func layout() {
        let text = CaddyConfiguration(
            layout: MachineLayout(dataDirectory: "/data dir", worktree: "/w", publicPort: 9000, serverPort: 9001, appPort: 9002),
            publicURL: "http://localhost:9000"
        ).render()
        #expect(text.contains("\n:9000 {\n"))
        #expect(text.contains("reverse_proxy 127.0.0.1:9001 {"))
        #expect(text.contains("reverse_proxy 127.0.0.1:9002 {"))
        #expect(text.contains("header_up X-Forwarded-Proto http\n"))
        #expect(text.contains(#"output file "/data dir/caddy/access.log""#))
    }
}

/// What somebody is told when the preview is empty, which is the likeliest thing they will ever
/// read from this machine.
@Suite("The preview's port advice")
struct PreviewPortAdviceTests {
    @Test("a project serving somewhere else is told which port the preview reads and where to move")
    func namesBothPorts() {
        // The workspace that started this: the app on 8091, the preview reading 3000.
        let lines = PreviewRoutes.portAdvice(appPort: 3000, listening: [8080, 8081, 8091], reserved: [8080, 8081])
        let text = lines.joined(separator: "\n")
        #expect(text.contains("reads port 3000"))
        #expect(text.contains("8091"), "the port their app is actually on")
        #expect(text.contains("BLOOM_APP_PORT"), "named, because every script is handed it")
        #expect(!text.contains("8080") && !text.contains("8081"),
                "Bloom's own ports are not an answer to where the app is")
    }

    @Test("nothing to say when the app's port is listening")
    func silentWhenThePortIsRight() {
        #expect(PreviewRoutes.portAdvice(appPort: 3000, listening: [3000, 8080], reserved: [8080, 8081]).isEmpty,
                "then the port is not the problem and a paragraph about it is noise")
    }

    @Test("a machine with nothing up says that instead of offering a port")
    func nothingListening() {
        let text = PreviewRoutes.portAdvice(appPort: 3000, listening: [8080, 8081], reserved: [8080, 8081]).joined(separator: "\n")
        #expect(text.contains("has not started yet"))
        #expect(!text.contains("Serve the app on"), "there is nowhere to point them")
    }
}

@Suite("Listening ports")
struct ListeningPortsTests {
    @Test("only sockets in LISTEN are read, and the port comes out of the hex")
    func parsesTheProcTable() {
        // Two rows from a real /proc/net/tcp: one listening on 8080 (1F90), one established.
        let table = """
          sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 00000000:1F90 00000000:0000 0A 00000000:00000000 00:00000000  00000000  1000        0 22330 1
           1: 0100007F:1F91 0100007F:C350 01 00000000:00000000 00:00000000  00000000  1000        0 22331 1
           2: 0100007F:1F99 00000000:0000 0A 00000000:00000000 00:00000000  00000000  1000        0 32251 1
        """
        #expect(ListeningPorts.parse(table) == [8080, 8089])
    }

    @Test("a table that is not there answers nothing rather than throwing")
    func missingFilesAreEmpty() {
        #expect(ListeningPorts.current(paths: ["/no/such/file"]).isEmpty)
    }
}

/// Where the preview lands after its cookie is set: a path on this origin, and never anywhere else.
@Suite("The preview's landing path")
struct PreviewLandingTests {
    @Test("a path on this origin is kept, with its query")
    func keepsAPath() {
        #expect(PreviewRoutes.landing("/dashboard") == "/dashboard")
        #expect(PreviewRoutes.landing("/orders?status=open#top") == "/orders?status=open#top")
        #expect(PreviewRoutes.landing(nil) == "/")
        #expect(PreviewRoutes.landing("/app/./orders/../orders") == "/app/./orders/../orders",
                "a path that normalises to somewhere safe is sent as given")
    }

    @Test("anything that could leave this origin, split the header or reach the machine lands on the root")
    func refusesEverythingElse() {
        for hostile in ["https://evil.example", "//evil.example/x", "/\\evil.example", "dashboard",
                        "/a\r\nSet-Cookie: x=1", "/_bloom/preview/check", "/_bloom", "/_bloom?x=1",
                        "/" + String(repeating: "a", count: 3_000),
                        // Encoded or dotted, each of these is `/_bloom` or another host by the time a
                        // browser or Caddy reads it; runbloom.app's check on the way in is literal.
                        "/%5Fbloom/preview/check", "/%5fbloom", "/./_bloom/x", "/app/../_bloom/x",
                        "/%2F%2Fevil.example", "/%252F%252Fevil.example", "/%5C%5Cevil.example",
                        "/%255Fbloom/x", "/_BLOOM/x", "/a%0D%0ASet-Cookie:x=1"] {
            #expect(PreviewRoutes.landing(hostile) == "/", "\(hostile) was let through")
        }
    }
}
