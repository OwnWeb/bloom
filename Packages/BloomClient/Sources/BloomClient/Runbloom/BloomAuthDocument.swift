import Foundation

/// `GET /.well-known/bloom-auth`: where runbloom.app signs people in, and the client a Mac signs
/// in as.
///
/// Read rather than written into the app, so a development runbloom.app behind a tunnel publishes
/// its own addresses and the app needs nothing but its origin. Every endpoint has to be on the
/// origin that was asked, over HTTPS (plain HTTP only for a loopback development server), because
/// a document that pointed sign in at another host would hand that host the person's credentials.
public struct BloomAuthDocument: Codable, Sendable, Hashable {
    public var issuer: URL
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var revocationEndpoint: URL?
    public var apiBaseURL: URL
    public var clients: [String: Client]

    public struct Client: Codable, Sendable, Hashable {
        public var clientID: String
        public var name: String?
        public var redirectURIs: [String]

        public init(clientID: String, name: String? = nil, redirectURIs: [String]) {
            self.clientID = clientID
            self.name = name
            self.redirectURIs = redirectURIs
        }

        enum CodingKeys: String, CodingKey {
            case name
            case clientID = "client_id"
            case redirectURIs = "redirect_uris"
        }
    }

    public init(
        issuer: URL, authorizationEndpoint: URL, tokenEndpoint: URL, revocationEndpoint: URL? = nil, apiBaseURL: URL,
        clients: [String: Client]
    ) {
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.revocationEndpoint = revocationEndpoint
        self.apiBaseURL = apiBaseURL
        self.clients = clients
    }

    enum CodingKeys: String, CodingKey {
        case issuer, clients
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case revocationEndpoint = "revocation_endpoint"
        case apiBaseURL = "api_base_url"
    }

    /// The Mac client, checked: its redirect has to be the one this build of the app answers.
    public func macClient(redirect: String) throws -> Client {
        guard let client = clients["mac"], !client.clientID.isEmpty else {
            throw RunbloomRefusal(status: 200, code: "sign_in_unavailable", message: "runbloom.app does not offer sign in for Bloom for Mac yet.")
        }
        guard client.redirectURIs.contains(redirect) else {
            throw RunbloomRefusal(status: 200, code: "sign_in_unavailable", message: "runbloom.app does not accept sign in from this build of Bloom (\(redirect)).")
        }
        return client
    }

    /// Refuses a document whose endpoints are not all on `origin`.
    public func validate(origin: URL) throws {
        let endpoints = [issuer, authorizationEndpoint, tokenEndpoint, apiBaseURL] + (revocationEndpoint.map { [$0] } ?? [])
        for url in endpoints where !Self.sameOrigin(url, origin) {
            throw RunbloomRefusal(status: 200, code: "sign_in_unavailable", message: "runbloom.app advertised a sign in address on another host (\(url.host() ?? url.absoluteString)).")
        }
    }

    static func sameOrigin(_ url: URL, _ origin: URL) -> Bool {
        guard url.user == nil, url.password == nil, url.fragment == nil,
              url.scheme == origin.scheme, url.host()?.lowercased() == origin.host()?.lowercased(), url.port == origin.port else { return false }
        return url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host() ?? ""))
    }

    public static func url(for origin: URL) -> URL {
        origin.appending(path: ".well-known/bloom-auth")
    }
}

/// Where this build of Bloom finds runbloom.app, and the redirect it signs in with.
public struct RunbloomEnvironment: Sendable, Hashable {
    public var origin: URL
    /// `bloom` for the installed app and `bloomdev` for Bloom Dev, which is what keeps the two from
    /// catching each other's sign in.
    public var urlScheme: String

    public init(origin: URL, urlScheme: String) {
        self.origin = origin
        self.urlScheme = urlScheme
    }

    public static let productionOrigin = URL(string: "https://runbloom.app")!

    public var redirect: String { "\(urlScheme)://oauth/callback" }

    /// Reads the environment: `BLOOM_RUNBLOOM_URL` (a development runbloom.app) wins over the
    /// setting, which wins over production. An address that is not an origin is ignored rather
    /// than trusted, because sign in sends credentials wherever this points.
    public static func resolve(environment: [String: String], setting: String?, urlSchemes: [String]) -> RunbloomEnvironment {
        let scheme = urlSchemes.first { $0 == "bloomdev" } ?? urlSchemes.first { $0 == "bloom" } ?? "bloom"
        for candidate in [environment["BLOOM_RUNBLOOM_URL"], setting] {
            if let candidate, let origin = origin(candidate) {
                return RunbloomEnvironment(origin: origin, urlScheme: scheme)
            }
        }
        return RunbloomEnvironment(origin: productionOrigin, urlScheme: scheme)
    }

    static func origin(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), let host = components.host, !host.isEmpty else { return nil }
        guard components.scheme == "https" || (components.scheme == "http" && ["localhost", "127.0.0.1"].contains(host)) else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard components.user == nil, components.password == nil else { return nil }
        return components.url
    }
}
