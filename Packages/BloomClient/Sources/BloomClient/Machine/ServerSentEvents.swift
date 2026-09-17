import Foundation

/// Server-sent events framing, a line at a time.
///
/// Written out rather than borrowed from `EventSource`, which cannot send an `Authorization`
/// header and so cannot be used at all: see "Clients other than the Mac" in
/// docs/REMOTE-WORKSPACES.md. The rules are the specification's, cut to what bloom-server sends:
/// `event:`, `id:` and `data:` fields, an empty line ending an event, and `:` comments, which are
/// its keep-alives and mean nothing.
public struct ServerSentEvents: Sendable {
    public struct Event: Sendable, Hashable {
        public var name: String
        public var id: String?
        public var data: String
    }

    private var name = ""
    private var id: String?
    private var data: [String] = []

    public init() {}

    /// Feeds one line without its line ending, and answers the event it completed, if any.
    public mutating func feed(_ line: String) -> Event? {
        if line.isEmpty {
            defer { name = ""; id = nil; data = [] }
            guard !data.isEmpty else { return nil }
            return Event(name: name.isEmpty ? "message" : name, id: id, data: data.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": name = String(value)
        case "id": if !value.contains("\0") { id = String(value) }
        case "data": data.append(String(value))
        default: break
        }
        return nil
    }
}
