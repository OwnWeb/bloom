import Foundation

/// tmux control mode, read and written.
///
/// Control mode hands over terminal bytes without the relay being able to run anything beyond the
/// commands built here. Output arrives as `%output` lines with every byte below a space, and the
/// backslash, escaped as three octal digits. Replies to commands arrive between `%begin` and
/// `%end`. Input goes back as hex so that a keystroke can never be read as a tmux command: a
/// pasted `;kill-server` is bytes to send, not a second command.
struct TmuxControlOutput {
    private var block: String?
    // The first replies are to attach, resize, the screen capture and the cursor position, in
    // that order, which is what `RemoteTerminalAttachment` sends as it starts.
    private var blockNumber = -1
    private var captured: [String] = []
    private let restoringScreen: Bool

    init(restoringScreen: Bool = false) { self.restoringScreen = restoringScreen }

    mutating func take(_ line: String) -> Data? {
        if let block {
            if line == "%end " + block || line == "%error " + block {
                self.block = nil
                defer { captured.removeAll() }
                guard restoringScreen, line.hasPrefix("%end ") else { return nil }
                if blockNumber == 2 { return Data(("\u{1b}[2J\u{1b}[H" + captured.joined(separator: "\r\n")).utf8) }
                if blockNumber == 3, let position = captured.first {
                    let values = position.split(separator: " ").compactMap { Int($0) }
                    guard values.count == 2, values.allSatisfy({ (0..<10_000).contains($0) }) else { return nil }
                    return Data("\u{1b}[\(values[1] + 1);\(values[0] + 1)H".utf8)
                }
                return nil
            }
            if restoringScreen, blockNumber <= 3 {
                captured.append(line)
                return nil
            }
            return Data((line + "\r\n").utf8)
        }
        if line.hasPrefix("%begin ") {
            block = String(line.dropFirst(7))
            blockNumber += 1
            return nil
        }
        guard line.hasPrefix("%output "), let separator = line.dropFirst(8).firstIndex(of: " ") else { return nil }
        let bytes = Array(line[line.index(after: separator)...].utf8)
        var output = Data()
        var index = 0
        while index < bytes.count {
            if bytes[index] == 92, index + 3 < bytes.count, bytes[(index + 1)...(index + 3)].allSatisfy({ (48...55).contains($0) }) {
                let value = Int(bytes[index + 1] - 48) * 64 + Int(bytes[index + 2] - 48) * 8 + Int(bytes[index + 3] - 48)
                guard value <= 255 else { return nil }
                output.append(UInt8(value))
                index += 4
            } else {
                output.append(bytes[index])
                index += 1
            }
        }
        return output
    }

    static let inputLimit = 16_384

    /// One `send-keys` for up to `inputLimit` bytes. Nil for nothing to send or too much at once;
    /// `RemoteTerminalAttachment.write` splits a larger paste before it gets here.
    static func input(_ data: Data, session: String) -> String? {
        guard !data.isEmpty, data.count <= inputLimit else { return nil }
        return "send-keys -H -t =" + session + ": " + data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    static func resize(columns: Int, rows: Int) -> String? {
        guard (2...500).contains(columns), (2...300).contains(rows) else { return nil }
        return "refresh-client -C \(columns),\(rows)"
    }
}
