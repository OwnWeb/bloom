import Foundation

/// What a Bloom Cloud machine's picture is called once it is on this Mac.
///
/// **One path component, whatever the machine said.** The name comes off the wire, and a path from
/// a machine is not trusted to say where on this Mac a file is written: `../../Library/whatever`
/// must land inside the cache folder like anything else. A machine names its copies by their
/// digest, so the last component of an honest path is already a safe, unique, stable name and is
/// kept, which also keeps its extension for AVKit and Quick Look. Anything else is replaced by a
/// hash of the whole path, which is as stable and cannot climb out.
public enum CloudMediaFileName {
    public static func of(_ path: String) -> String {
        let last = (path as NSString).lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let isPlain = !last.isEmpty && !last.hasPrefix(".")
            && last.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
        if isPlain { return last }
        // FNV-1a over the path's bytes: a name, not a secret, so it needs to be stable and nothing else.
        let hash = path.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return String(hash, radix: 16)
    }
}
