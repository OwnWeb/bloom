import Foundation
import Testing
@testable import BloomRunner

@Suite("The Caddyfile in front of the machine")
struct CaddyConfigurationTests {
    static let configuration = CaddyConfiguration(
        layout: MachineLayout(dataDirectory: "/home/sprite/.bloom", worktree: "/home/sprite/workspace"),
        publicURL: "https://bloom-01k5.sprites.app"
    )

    @Test("HTTPS and the admin endpoint are off, and it listens on the URL port")
    func globalOptions() {
        let text = Self.configuration.render()
        #expect(text.contains("\tadmin off\n"))
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
