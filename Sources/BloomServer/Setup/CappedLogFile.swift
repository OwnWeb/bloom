import Foundation

/// A log file that starts empty and never grows past a limit.
///
/// A dev server left running for a week on a 99 GB disk is still a disk that fills: `npm run dev`
/// with a noisy watcher writes megabytes an hour, and nothing on the machine rotates logs. When the
/// limit is reached the file starts again with a line saying so, because the newest output is the
/// part anybody opens a service log to read.
///
/// Used by one task at a time, which is why it is a plain class with no lock.
final class CappedLogFile {
    private let path: String
    private let limit: Int
    private var handle: FileHandle?
    private var written = 0

    init(path: String, limit: Int) {
        self.path = path
        self.limit = limit
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
    }

    func append(_ line: String) {
        guard let handle else { return }
        let data = Data((line + "\n").utf8)
        if written + data.count > limit {
            let megabytes = limit / 1_048_576
            let note = Data("[bloom] This log reached \(megabytes > 0 ? "\(megabytes) MB" : "\(limit) bytes") and was started again.\n".utf8)
            try? handle.truncate(atOffset: 0)
            try? handle.seek(toOffset: 0)
            try? handle.write(contentsOf: note)
            written = note.count
        }
        try? handle.write(contentsOf: data)
        written += data.count
    }

    func close() {
        try? handle?.close()
        handle = nil
    }

    deinit {
        try? handle?.close()
    }
}
