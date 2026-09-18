import BloomProtocol
import Foundation

/// A Cloud row's payload turned back into bytes, with its keys in the order an agent CLI writes
/// them rather than sorted.
///
/// **Every cheap test on a transcript row reads its first few hundred bytes**, because deciding
/// from a decode is the cost those tests exist to avoid: `TranscriptRowInk` looks for
/// `"subtype":"init` in the first 256, `BackgroundWake` and `ContextCompaction` for their subtypes
/// in the same 256, `MediaShowRow` and `WorkspaceSayRow` for a tool's name in the first 1,024. All
/// of them are true of what the CLI writes, which is `type` and `subtype` first and a tool call's
/// `name` before its `input`.
///
/// **A Cloud row did not arrive like that.** The machine sends a payload as a JSON object, the wire
/// decodes it into `WireValue`, whose objects are dictionaries, and the one way back to bytes was
/// `WireValue.data`, which sorts the keys. Sorted, an init row's `subtype` sits behind
/// `mcp_servers`, `plugins`, `skills` and `slash_commands`, some kilobytes in, and a tool call's
/// `name` sits behind its `input`. The fold was told the init row draws nothing, so "Started with"
/// stood outside the group in a Cloud workspace and inside it in a local one; and a `media_show`
/// with a long caption would have folded away. The first of those is in the owner's Bloom Cloud
/// screenshots, which is where it was found.
///
/// **The order the machine received cannot be recovered here**: it is gone the moment the frame is
/// decoded, and only a wire that carried the payload as a string would keep it. What can be done is
/// to write the keys every one of those tests depends on where the CLI writes them, at every depth,
/// and the rest sorted after them so the bytes are still stable. One fix at the one place Cloud
/// bytes are made, rather than one per test that reads them.
public enum CloudPayloadBytes {
    /// The keys written first, in this order, wherever they occur. The CLI's own order for the two
    /// envelopes a transcript row comes in: `type` then `subtype` for a system line, and `type`,
    /// `id`, `name` for a tool call ahead of its `input`.
    ///
    /// **This list is the limit of the fix.** A new test that reads the start of a payload for a
    /// key not named here works on a local row and fails on a Cloud one, because everything else
    /// is written sorted. Add its key here when you write it, and a case to
    /// `CloudPayloadBytesTests` beside the two that are there. The exact fix is the wire carrying a
    /// payload as the string the machine received, which nobody needed yet.
    static let leadingKeys = ["type", "subtype", "id", "name"]

    public static func data(_ value: WireValue) -> Data {
        var out = ""
        write(value, into: &out)
        return Data(out.utf8)
    }

    private static func write(_ value: WireValue, into out: inout String) {
        switch value {
        case .null: out += "null"
        case .bool(let flag): out += flag ? "true" : "false"
        case .number(let number):
            // As `WireValue.encode` writes it: a whole number without a decimal point.
            if number.rounded() == number, abs(number) < 9_007_199_254_740_992 {
                out += String(Int64(number))
            } else {
                out += "\(number)"
            }
        case .string(let text): writeString(text, into: &out)
        case .array(let items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                write(item, into: &out)
            }
            out += "]"
        case .object(let fields):
            out += "{"
            var first = true
            for key in orderedKeys(fields.keys) {
                guard let field = fields[key] else { continue }
                if !first { out += "," }
                first = false
                writeString(key, into: &out)
                out += ":"
                write(field, into: &out)
            }
            out += "}"
        }
    }

    static func orderedKeys(_ keys: Dictionary<String, WireValue>.Keys) -> [String] {
        let leading = leadingKeys.filter(keys.contains)
        return leading + keys.filter { !leadingKeys.contains($0) }.sorted()
    }

    /// JSON's escaping, and nothing more: slashes are left alone, as `WireValue.data` left them.
    private static func writeString(_ text: String, into out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case let control where control.value < 0x20:
                out += String(format: "\\u%04x", control.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}
