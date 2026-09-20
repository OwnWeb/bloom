import Foundation

/// Which TCP ports something on this machine is listening on.
///
/// **For telling somebody why their preview is empty.** The preview proxies to `BLOOM_APP_PORT`,
/// and a project whose dev server listens somewhere else gets a page saying the app is not
/// answering, which is true and useless: the person then has to deduce that there is a port
/// contract at all. One Cloud workspace served on 8091 while the preview read 3000, and an agent
/// spent twenty-odd actions building a second proxy to bridge them. The machine knew both numbers
/// the whole time.
///
/// Read from `/proc` rather than by running `ss`, because this is reached from an HTTP handler and
/// a subprocess there is a hang waiting to happen: `/proc/net/tcp` is two file reads and cannot
/// wedge. It answers ports and not process names; the port is the actionable half, and naming the
/// process would mean walking every `/proc/<pid>/fd` to match socket inodes.
public enum ListeningPorts {
    /// `st` in `/proc/net/tcp` for a socket in LISTEN.
    private static let listening = "0A"

    public static func current(
        paths: [String] = ["/proc/net/tcp", "/proc/net/tcp6"]
    ) -> [Int] {
        var ports = Set<Int>()
        for path in paths {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            ports.formUnion(parse(text))
        }
        return ports.sorted()
    }

    /// The listening ports in one `/proc/net/tcp` table.
    static func parse(_ text: String) -> [Int] {
        var ports: [Int] = []
        for line in text.split(separator: "\n").dropFirst() {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count > 3, columns[3] == listening,
                  let hex = columns[1].split(separator: ":").last,
                  let port = Int(hex, radix: 16) else { continue }
            ports.append(port)
        }
        return ports
    }
}
