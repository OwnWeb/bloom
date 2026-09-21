#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Ignored files a setup run created or changed, recorded by content rather than by name.
///
/// Git can prove that a path is ignored, but that does not make it disposable: `.env`, a local
/// database and a cache can all hold work that exists nowhere else. Bloom has one stronger fact
/// while it runs setup itself. It can compare the ignored files immediately before and after the
/// run, then keep the fingerprints inside its shielded scratch folder. An unchanged match is
/// setup output. A later edit, a new file, an unreadable file or a missing manifest is not.
enum SetupArtifacts {
    struct Snapshot: Sendable {
        var fingerprints: [String: String]
    }

    private struct Manifest: Codable {
        var fingerprints: [String: String]
    }

    private static let relativeManifest = WorktreeScratch.generated + "/setup-artifacts.json"
    private static let directoryLimit = 2_000

    static func snapshot(in worktree: String) async -> Snapshot {
        guard let candidates = try? await Git.ignoredCandidates(worktree: worktree) else {
            return Snapshot(fingerprints: [:])
        }
        return Snapshot(fingerprints: fingerprints(of: candidates, in: worktree))
    }

    /// Keeps earlier setup output only while its bytes still match, then adds files this run
    /// changed. A user edit made between setup runs therefore stops matching instead of being
    /// blessed again merely because setup was launched later.
    static func recordChanges(from before: Snapshot, in worktree: String) async {
        let after = await snapshot(in: worktree)
        let previous = load(in: worktree)?.fingerprints ?? [:]
        var recorded = previous.filter { after.fingerprints[$0.key] == $0.value }
        for (path, fingerprint) in after.fingerprints where before.fingerprints[path] != fingerprint {
            recorded[path] = fingerprint
        }
        WorktreeScratch.shield(WorktreeScratch.generated, in: worktree)
        let url = URL(fileURLWithPath: worktree).appending(path: relativeManifest)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Manifest(fingerprints: recorded)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Whether every file currently covered by a collapsed ignored path is unchanged setup
    /// output. Missing files are harmless; any extra or changed file makes the whole path block.
    static func containsOnlyRecordedFiles(_ path: String, in worktree: String) -> Bool {
        guard let recorded = load(in: worktree)?.fingerprints else { return false }
        let current = fingerprints(of: [path], in: worktree)
        guard !current.isEmpty else { return false }
        return current.allSatisfy { recorded[$0.key] == $0.value }
    }

    private static func load(in worktree: String) -> Manifest? {
        let url = URL(fileURLWithPath: worktree).appending(path: relativeManifest)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    private static func fingerprints(of candidates: [String], in worktree: String) -> [String: String] {
        let manager = FileManager.default
        var result: [String: String] = [:]

        for candidate in candidates {
            let relative = candidate.hasSuffix("/") ? String(candidate.dropLast()) : candidate
            let root = (worktree as NSString).appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: root, isDirectory: &isDirectory) else { continue }

            if (try? manager.destinationOfSymbolicLink(atPath: root)) != nil {
                if let fingerprint = fingerprint(root) { result[relative] = fingerprint }
                continue
            }
            if !isDirectory.boolValue {
                if let fingerprint = fingerprint(root) { result[relative] = fingerprint }
                continue
            }

            guard let walk = manager.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            ) else { continue }
            var found: [(String, String)] = []
            var exceededLimit = false
            for case let url as URL in walk {
                if (try? manager.destinationOfSymbolicLink(atPath: url.path)) != nil {
                    walk.skipDescendants()
                }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                if values?.isDirectory == true,
                   (try? manager.destinationOfSymbolicLink(atPath: url.path)) == nil { continue }
                let relativePath = String(url.path.dropFirst(worktree.count + 1))
                guard let value = fingerprint(url.path) else {
                    exceededLimit = true
                    break
                }
                found.append((relativePath, value))
                if found.count > directoryLimit {
                    exceededLimit = true
                    break
                }
            }
            if !exceededLimit {
                for (path, value) in found { result[path] = value }
            }
        }
        return result
    }

    private static func fingerprint(_ path: String) -> String? {
        let manager = FileManager.default
        if let destination = try? manager.destinationOfSymbolicLink(atPath: path) {
            return digest(Data("link\u{0}\(destination)".utf8))
        }
        guard let data = manager.contents(atPath: path) else { return nil }
        return digest(data)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
