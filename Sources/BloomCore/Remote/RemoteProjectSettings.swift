import Foundation

/// What a repository says about running as a Cloud workspace: the `prepare` and `resume` scripts
/// either side of `setup`, the services the server supervises, and a size hint.
///
/// A type of its own rather than more fields on `RepoSettings`, because none of it means anything
/// on a Mac and the Mac's settings window, writer and layering tests should not have to learn it.
/// It reads the same files through the same TOML reader, so a repository still has one settings
/// file. Only the repository's files are read, never the home directory ones: on a server the home
/// directory belongs to the machine, and a workspace should run the way its repository says.
///
/// A file states each value the way `scripts.setup` is stated, and a later file replaces what an
/// earlier one said; `[[services]]` is replaced as a whole list. Problems are sentences to show a
/// person rather than a throw, because one misnamed dependency should not stop setup reporting
/// everything else it found.
public struct RemoteProjectSettings: Sendable, Hashable {
    public struct Service: Sendable, Hashable {
        /// Stable repository-declared authority identity. Display-name changes do not change it.
        public var id: String
        public var name: String
        public var command: String
        /// The one service the preview routes to.
        public var http: Bool
        /// When the service counts as started, such as `http:/up`. Nil means as soon as it runs.
        public var ready: String?
        public var dependsOn: [String]

        public init(id: String, name: String, command: String, http: Bool = false, ready: String? = nil,
                    dependsOn: [String] = []) {
            self.id = id
            self.name = name
            self.command = command
            self.http = http
            self.ready = ready
            self.dependsOn = dependsOn
        }
    }

    public var prepareScript: String?
    public var prepareFile: ScriptFile?
    public var resumeScript: String?
    public var resumeFile: ScriptFile?
    public var services: [Service] = []
    public var size: String?
    public var problems: [String] = []

    public init() {}

    /// The service the preview routes to, when exactly one says so.
    public var httpService: Service? {
        let marked = services.filter(\.http)
        return marked.count == 1 ? marked.first : nil
    }

    public static func load(repo: String) -> Self {
        var settings = Self()
        for path in SettingsLoader.repoPaths(repo: repo) {
            let toml: TOMLValue
            do {
                guard let parsed = try TOML.parse(contentsOf: path) else { continue }
                toml = parsed
            } catch let error as TOMLError {
                settings.problems.append("\(path) was skipped: line \(error.line) could not be read (\(error.message)).")
                continue
            } catch {
                settings.problems.append("\(path) was skipped: it could not be read.")
                continue
            }
            settings.apply(toml, from: path, repo: repo)
        }
        settings.problems += validate(settings.services)
        return settings
    }

    mutating func apply(_ toml: TOMLValue, from source: String, repo: String) {
        if let prepare = Self.script(toml, inline: "scripts.prepare", file: "scripts.prepare_file", repo: repo) {
            prepareScript = prepare.text
            prepareFile = prepare.file
        }
        if let resume = Self.script(toml, inline: "scripts.resume", file: "scripts.resume_file", repo: repo) {
            resumeScript = resume.text
            resumeFile = resume.file
        }
        if let stated = toml["remote.size"] {
            if let value = stated.stringValue {
                size = value.isEmpty ? nil : value
            } else {
                problems.append("\(source): remote.size has to be a string.")
            }
        }
        if let stated = toml["services"] {
            services = readServices(stated, from: source)
        }
    }

    /// The rule `SettingsLoader` applies to `scripts.setup`: a named file wins over an inline
    /// string in the same settings file, and an empty inline string states "no script".
    static func script(_ toml: TOMLValue, inline: String, file: String, repo: String) -> (text: String?, file: ScriptFile?)? {
        if let stated = toml[file]?.stringValue, !stated.isEmpty {
            let full = SettingsLoader.resolve(stated, repo: repo)
            guard let text = try? String(contentsOfFile: full, encoding: .utf8) else {
                return (nil, ScriptFile(path: stated, isMissing: true))
            }
            let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return (hasContent ? text : nil, ScriptFile(path: stated, isMissing: false))
        }
        guard let text = toml[inline]?.stringValue else { return nil }
        return (text.isEmpty ? nil : text, nil)
    }

    private mutating func readServices(_ value: TOMLValue, from source: String) -> [Service] {
        guard let entries = value.arrayValue else {
            problems.append("\(source): services has to be written as [[services]] tables.")
            return []
        }
        var read: [Service] = []
        for (index, entry) in entries.enumerated() {
            let label = "\(source): service \(index + 1)"
            guard let table = entry.tableValue else {
                problems.append("\(label) is not a table.")
                continue
            }
            let id = table["id"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
            let name = table["name"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let command = table["command"]?.stringValue,
                  !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                problems.append("\(label) has no command, so it was left out.")
                continue
            }
            var service = Service(id: id, name: name, command: command)
            if let http = table["http"] {
                if let flag = http.boolValue { service.http = flag } else { problems.append("\(label): http has to be true or false.") }
            }
            if let ready = table["ready"] {
                if let text = ready.stringValue, text.hasPrefix("http:/") {
                    service.ready = text
                } else {
                    problems.append("\(label): ready has to be a path to wait for, written like \"http:/up\".")
                }
            }
            if let depends = table["depends_on"] {
                if let names = depends.arrayValue, names.allSatisfy({ $0.stringValue != nil }) {
                    service.dependsOn = names.compactMap(\.stringValue)
                } else {
                    problems.append("\(label): depends_on has to be a list of service ids.")
                }
            }
            read.append(service)
        }
        return read
    }

    /// Everything wrong with a list of services, in the order a person would fix it.
    static func validate(_ services: [Service]) -> [String] {
        var problems: [String] = []
        var seenIDs: Set<String> = []
        var seenNames: Set<String> = []
        for service in services {
            if !validServiceID(service.id) {
                problems.append("A service has a missing or invalid id. Use lowercase letters, numbers, dots, underscores or hyphens.")
            } else if !seenIDs.insert(service.id).inserted {
                problems.append("More than one service has id \"\(service.id)\". Service ids have to be unique.")
            }
            if service.name.isEmpty {
                problems.append("A service has no name. Give every [[services]] entry a name.")
            } else if service.name.count > 100 {
                problems.append("Service \"\(service.id)\" has a name longer than 100 characters.")
            } else if !seenNames.insert(service.name).inserted {
                problems.append("More than one service is called \"\(service.name)\". Service names have to be unique.")
            }
        }
        for service in services where validServiceID(service.id) {
            for dependency in service.dependsOn where !seenIDs.contains(dependency) {
                problems.append("\"\(service.name)\" depends on \"\(dependency)\", which is not a service.")
            }
            if service.dependsOn.contains(service.id) {
                problems.append("\"\(service.name)\" depends on itself.")
            }
        }
        if let cycle = cycle(in: services) {
            problems.append("These services depend on each other in a circle: \(cycle.joined(separator: " -> ")).")
        }
        let http = services.filter(\.http).map(\.name)
        if http.count > 1 {
            problems.append("Only one service can set http = true, and \(http.count) do: \(http.joined(separator: ", ")).")
        }
        return problems
    }

    public static func validServiceID(_ id: String) -> Bool {
        guard (1...64).contains(id.utf8.count), let first = id.utf8.first,
              (97...122).contains(first) || (48...57).contains(first) else { return false }
        return id.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0) || $0 == 46 || $0 == 95 || $0 == 45
        }
    }

    /// The first loop of two or more services, named in order and closed on its first name. A
    /// service depending on itself is reported on its own above, so it is not repeated here.
    static func cycle(in services: [Service]) -> [String]? {
        var edges: [String: [String]] = [:]
        for service in services where validServiceID(service.id) {
            edges[service.id, default: []] += service.dependsOn.filter { $0 != service.id }
        }
        var finished: Set<String> = []
        var path: [String] = []

        func visit(_ name: String) -> [String]? {
            if let start = path.firstIndex(of: name) { return Array(path[start...]) + [name] }
            guard !finished.contains(name), edges[name] != nil else { return nil }
            path.append(name)
            for next in edges[name] ?? [] {
                if let found = visit(next) { return found }
            }
            path.removeLast()
            finished.insert(name)
            return nil
        }

        for service in services where validServiceID(service.id) {
            if let found = visit(service.id) { return found }
        }
        return nil
    }
}
