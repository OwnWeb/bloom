import BloomCore
import Foundation

/// Which executable on this host the person-bound foundation is willing to run, and whether a path
/// it was handed can be trusted with a credential.
///
/// **A path is not a guarantee, and this exists because one was treated as one.** The Runner named
/// `/usr/bin/gh` outright and required it to be there, which is true of the CI host and false of a
/// Sprite, where `gh` ships at `/.sprite/bin/gh`. Every Cloud workspace created on 21 September
/// 2026 failed on that: the machine built, the package installed, and the Runner refused to start
/// with `static host checks` while `gh` sat a directory away, root owned and perfectly usable. The
/// test that should have caught it built its own `gh` at the very path production does not use.
///
/// So the question moved from "is it there" to "is it trustworthy", which is the question that was
/// always meant. `isTrusted` is the attestor's own rule, and it is the only copy: every component
/// of the path, up to `/`, owned by root and writable by nobody else. A directory somebody else can
/// write to is a directory where the binary can be replaced between this check and the exec.
enum PersonBoundTrustedExecutable {
    /// Where a host might keep an executable the Runner needs. `Shell.which` is asked first, so a
    /// host that puts it somewhere new needs no change here; the list is what to fall back on when
    /// `PATH` is not the service's, and every answer is checked either way.
    static let searchDirectories = ["/usr/bin", "/usr/local/bin", "/.sprite/bin", "/bin"]

    /// The first trustworthy `name` on this host, or nil when there is none, which is a refusal to
    /// start rather than something to work around.
    static func find(_ name: String) -> String? {
        var candidates: [String] = []

        if let onPath = Shell.which(name) {
            candidates.append(onPath)
        }

        candidates.append(contentsOf: searchDirectories.map { "\($0)/\(name)" })

        return candidates.first(where: isTrusted)
    }

    /// Absolute, executable, and root's the whole way up.
    static func isTrusted(_ path: String) -> Bool {
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return false }

        return rootOwnsPath(path)
    }

    /// Resolved before it is walked, because a link in the middle of a path is a way to put
    /// somebody else's directory inside one that looks like root's.
    static func rootOwnsPath(_ path: String) -> Bool {
        var current = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path

        while current != "/" {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: current),
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == 0,
                  let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value,
                  mode & 0o022 == 0 else { return false }

            current = URL(fileURLWithPath: current).deletingLastPathComponent().path
        }

        return true
    }
}
