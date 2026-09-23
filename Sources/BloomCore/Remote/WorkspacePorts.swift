import Foundation

/// What is listening inside a Cloud workspace, said in words, and which local port a forward of it
/// gets on this Mac.
///
/// The machine answers `listening_ports` with numbers and nothing else, because reading
/// `/proc/net/tcp` is two file reads that cannot wedge, while naming the process behind a socket
/// means walking every `/proc/<pid>/fd` to match inodes (see `ListeningPorts`). So the naming
/// happens here, from the port alone. "PostgreSQL" is a guess from 5432 and is right almost always;
/// when it is wrong the number is still there beside it, which is the half that is actionable.
public enum WorkspacePorts {
    /// One port, as a person reads it.
    public struct Port: Sendable, Hashable, Identifiable, Comparable {
        public var number: Int
        /// What is probably listening there, or nil when nothing is known about the number.
        public var name: String?
        public var kind: Kind
        /// Bloom holds this one, so it can never be forwarded. See `ListeningPortRecord.reserved`.
        public var reserved: Bool
        /// The URL scheme a client of this service answers to, for a database somebody can open in
        /// an application. Nil for anything no application registers a scheme for.
        public var scheme: String?

        public var id: Int { number }

        /// The name when there is one, the number when there is not. What a row's title shows.
        public var title: String { name ?? "Port \(number)" }

        public static func < (lhs: Port, rhs: Port) -> Bool { lhs.number < rhs.number }

        public init(number: Int, name: String? = nil, kind: Kind = .other, reserved: Bool = false, scheme: String? = nil) {
            self.number = number
            self.name = name
            self.kind = kind
            self.reserved = reserved
            self.scheme = scheme
        }
    }

    /// What a client can usefully do with a port, which is the only distinction the window draws.
    public enum Kind: String, Sendable, Hashable {
        /// Something that speaks HTTP, so a browser can open it.
        case http
        /// A database, which is handed to whichever application takes that kind of URL.
        case database
        /// Anything else. Forwardable, but Bloom has nothing to open it with.
        case other
    }

    /// The numbers worth naming. Short on purpose: a table that guesses at everything is a table
    /// that is confidently wrong, and an unnamed row still forwards.
    ///
    /// A database's scheme is the one its clients register with macOS, which is how an application
    /// that can take the connection is found: TablePlus answers `postgresql` and `redis`, Postico
    /// answers `postgresql` only, and Memcached has no scheme anybody registers.
    static let known: [Int: (name: String, kind: Kind, scheme: String?)] = [
        3000: ("Dev server", .http, nil),
        3306: ("MySQL", .database, "mysql"),
        4200: ("Angular", .http, nil),
        5173: ("Vite", .http, nil),
        5432: ("PostgreSQL", .database, "postgresql"),
        6006: ("Storybook", .http, nil),
        6379: ("Redis", .database, "redis"),
        7700: ("Meilisearch", .http, nil),
        8000: ("Dev server", .http, nil),
        8025: ("Mailpit", .http, nil),
        8080: ("Dev server", .http, nil),
        9200: ("Elasticsearch", .http, nil),
        9600: ("Typesense", .http, nil),
        11211: ("Memcached", .database, nil),
        27017: ("MongoDB", .database, "mongodb"),
    ]

    /// A port as a person reads it, from its number alone.
    public static func port(_ number: Int, reserved: Bool = false) -> Port {
        let known = known[number]
        return Port(number: number, name: known?.name, kind: known?.kind ?? .other, reserved: reserved, scheme: known?.scheme)
    }

    /// The machine's answer, named and sorted, with loopback noise dropped.
    ///
    /// **Ports below 1024 are left out.** A Sprite runs `sshd`, Caddy and whatever the image
    /// brought, and a list whose first four rows are things nobody asked for buries the one row
    /// somebody wanted. Anything a project starts is above 1024 in practice.
    public static func describe(_ records: [(port: Int, reserved: Bool)]) -> [Port] {
        var seen = Set<Int>()
        var ports: [Port] = []
        for record in records where record.port >= 1024 && !seen.contains(record.port) {
            seen.insert(record.port)
            ports.append(port(record.port, reserved: record.reserved))
        }
        return ports.sorted()
    }

    // MARK: - Where a forward lands on this Mac

    /// The lowest local port a forward may take, and how many above it.
    ///
    /// **Below the range macOS hands out for outgoing connections**, which starts at 49152
    /// (`net.inet.ip.portrange.first`). The first version started at 50,000 and said it was below
    /// that range, which it was not: every stable port it chose was one the system could give to a
    /// browser's next socket, and a forward that fell through to its second candidate because
    /// Safari happened to hold its first would move the address TablePlus had saved.
    static let lowestLocal = 40_000
    static let localRange = 5_000
    static let firstEphemeral = 49_152

    /// The local ports to try for one workspace's remote port, best first.
    ///
    /// **The first candidate is stable across restarts, and that is the whole point.** Somebody
    /// saves `localhost:55432` in TablePlus once; a number that moved every launch would make the
    /// saved connection a lie, and the feature would be "open Bloom, read the number, edit
    /// TablePlus" rather than "connect". So the choice is a hash of the workspace and the remote
    /// port rather than whatever the system offers.
    ///
    /// **`Hasher` cannot be used for this.** Swift seeds it per process, so the same workspace
    /// would hash to a different port on the next launch, which is exactly the bug this avoids.
    /// FNV-1a is written out here because it is stable, tiny, and its only job is to spread.
    ///
    /// The rest of the sequence walks upwards from there, because the first choice can be taken by
    /// another workspace, another Bloom, or something else on this Mac entirely.
    public static func localCandidates(workspace: String, port: Int, count: Int = 32) -> [Int] {
        let offset = Int(fnv1a("\(workspace):\(port)") % UInt64(localRange))
        return (0..<count).map { lowestLocal + (offset + $0) % localRange }
    }

    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    // MARK: - Handing a forward on

    /// What a forwarded port can be opened with, beyond copying its address.
    public enum Opening: Sendable, Hashable {
        /// A page, opened in Bloom's own browser pane rather than handed to Safari, because it is
        /// part of the workspace and belongs beside its transcript.
        case browser(URL)
        /// A connection, handed to an application that registers the URL's scheme with macOS. No
        /// such application installed means nothing to offer, not a button that fails.
        case application(URL)
    }

    /// Which of the two a forwarded port gets, or nil for one Bloom has nothing to open with.
    ///
    /// **A web server gets `localhost`, a database gets `127.0.0.1`.** A browser treats both as
    /// this Mac, and a page's own links and cookies are usually written for `localhost`. A database
    /// client does not: the MySQL client library reads `localhost` as "use the Unix socket", so a
    /// forward handed to it by that name would connect to a local MySQL, or to nothing, and never
    /// to the workspace.
    ///
    /// An unnamed port gets nothing. It may well speak HTTP, but a guess that opens a debugger's
    /// port in a browser is worse than a row that only copies its address.
    ///
    /// A database's `login` goes into the URL, because without one the client connects as this
    /// Mac's user. See `DatabaseLogin`.
    public static func opening(_ port: Port, localPort: Int, login: DatabaseLogin? = nil) -> Opening? {
        guard !port.reserved, (1...65_535).contains(localPort) else { return nil }
        switch port.kind {
        case .http:
            return URL(string: "http://localhost:\(localPort)").map(Opening.browser)
        case .database:
            guard let scheme = port.scheme else { return nil }
            var address = URLComponents()
            address.scheme = scheme
            address.host = "127.0.0.1"
            address.port = localPort
            address.user = login?.user
            address.password = login?.password
            address.path = login?.database.map { "/" + $0 } ?? ""
            return address.url.map(Opening.application)
        case .other:
            return nil
        }
    }

    /// The local port a forwarded page's address is on, or nil for any other address.
    ///
    /// **How a Cloud workspace tells its two kinds of browser tab apart.** Both are browser tabs,
    /// and the preview's is drawn from a single use exchange that ignores the tab's address, so a
    /// forwarded page opened in it would show the project's app instead. The preview is always the
    /// machine's own HTTPS host and never loopback, so an address on this Mac, in the range a
    /// forward binds, is one of these and nothing else.
    public static func forwardedLocalPort(in address: String) -> Int? {
        guard let url = URL(string: address), url.scheme == "http",
              let host = url.host(), host == "localhost" || host == "127.0.0.1",
              let port = url.port, (lowestLocal..<(lowestLocal + localRange)).contains(port) else { return nil }
        return port
    }
}
