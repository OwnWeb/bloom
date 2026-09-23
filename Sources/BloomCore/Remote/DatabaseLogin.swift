import Foundation

/// Who to connect to a forwarded database as, read from the workspace's own `.env`.
///
/// **A connection URL with no user is a connection as whoever is sitting at this Mac.** TablePlus
/// handed `postgresql://127.0.0.1:41499` fills the user in from macOS, so the first Open against a
/// Cloud workspace's Postgres failed with `role "freek" does not exist`: a role that could only
/// exist on this Mac, asked of a machine that has never had such a user. The project already says who
/// its app connects as, in the file its framework reads, so that is who the client connects as too.
///
/// **Only a connection of the same kind is taken.** A Laravel `.env` names one default connection,
/// and its `DB_USERNAME` belongs to whichever that is; handing MySQL's login to a Postgres forward
/// would fail as surely as no login did, and less legibly. A URL-style variable is matched by its
/// own scheme for the same reason.
public struct DatabaseLogin: Sendable, Hashable {
    public var user: String?
    public var password: String?
    public var database: String?

    public init(user: String? = nil, password: String? = nil, database: String? = nil) {
        self.user = user
        self.password = password
        self.database = database
    }

    var isEmpty: Bool { user == nil && password == nil && database == nil }

    /// The login for a database spoken to with `scheme`, or nil when the file says nothing usable.
    public static func from(dotenv text: String, scheme: String) -> DatabaseLogin? {
        let values = parse(dotenv: text)
        let login: DatabaseLogin? = switch scheme {
        case "postgresql", "mysql":
            fromURL(values, scheme: scheme) ?? fromLaravel(values, scheme: scheme)
        case "redis":
            DatabaseLogin(user: values["REDIS_USERNAME"], password: values["REDIS_PASSWORD"])
        default:
            nil
        }
        return login?.isEmpty == false ? login : nil
    }

    /// `DB_URL` is Laravel's, `DATABASE_URL` everybody else's.
    private static func fromURL(_ values: [String: String], scheme: String) -> DatabaseLogin? {
        for key in ["DB_URL", "DATABASE_URL"] {
            guard let text = values[key], let url = URLComponents(string: text),
                  let found = url.scheme.map(normalised), found == scheme else { continue }
            let path = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
            return DatabaseLogin(user: url.user, password: url.password, database: path.isEmpty ? nil : path)
        }
        return nil
    }

    private static func fromLaravel(_ values: [String: String], scheme: String) -> DatabaseLogin? {
        if let connection = values["DB_CONNECTION"], normalised(connection) != scheme { return nil }
        return DatabaseLogin(user: values["DB_USERNAME"], password: values["DB_PASSWORD"], database: values["DB_DATABASE"])
    }

    /// Laravel's driver names and the common URL spellings, as the scheme a client registers.
    private static func normalised(_ name: String) -> String {
        switch name.lowercased() {
        case "pgsql", "postgres", "postgresql": "postgresql"
        case "mysql", "mariadb": "mysql"
        default: name.lowercased()
        }
    }

    /// `KEY=value` lines, as phpdotenv and its cousins read them: `export` allowed, a value in
    /// quotes taken whole, an unquoted one cut at ` #`. Empty values and Laravel's literal `null`
    /// are left out, because both mean "not set".
    static func parse(dotenv text: String) -> [String: String] {
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'",
               let close = value.dropFirst().firstIndex(of: quote) {
                value = String(value[value.index(after: value.startIndex)..<close])
            } else if let comment = value.range(of: " #") {
                value = value[..<comment.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            guard !key.isEmpty, !value.isEmpty, value.lowercased() != "null" else { continue }
            values[key] = value
        }
        return values
    }
}
