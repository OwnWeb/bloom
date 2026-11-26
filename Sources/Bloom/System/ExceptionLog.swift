import AppKit
import BloomCore
import ObjectiveC

/// AppKit traps on an exception raised in a display cycle without the uncaught handler or the crash
/// report keeping its reason, so this records it at the throw. A constraint loop's reason names the
/// window, not the view, so that case also lists the views still waiting for a constraint pass.
enum ExceptionLog {
    private static let maximumSuspects = 20
    /// A ceiling, not a rotation: past it the file starts again, losing what came before.
    private static let maximumFileBytes = 262_144
    private static let fileLock = NSLock()
    /// An exception thrown while recording one would otherwise deadlock on `fileLock`.
    private static let recordingKey = "ExceptionLog.recording"
    /// CoreFoundation's own preprocessor, which records the backtrace the crash report shows.
    private nonisolated(unsafe) static var previous: objc_exception_preprocessor?

    static func install() {
        previous = objc_setExceptionPreprocessor { object in
            if let exception = object as? NSException { ExceptionLog.record(exception) }
            return ExceptionLog.previous.map { $0(object) } ?? object
        }
    }

    /// `~/Library/Logs/Bloom/exceptions.log`, or the dev copy's own directory beside it.
    private static var fileURL: URL {
        let directory = Store.databaseDirectoryName(forBundleIdentifier: Bundle.main.bundleIdentifier)
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs/\(directory)/exceptions.log")
    }

    private static func record(_ exception: NSException) {
        let threadState = Thread.current.threadDictionary
        guard threadState[recordingKey] == nil else { return }
        threadState[recordingKey] = true
        defer { threadState.removeObject(forKey: recordingKey) }

        var lines = ["\(exception.name.rawValue): \(exception.reason ?? "no reason")"]
        let isConstraintFailure = exception.reason?.localizedCaseInsensitiveContains("constraints") == true
        if isConstraintFailure, Thread.isMainThread {
            lines += MainActor.assumeIsolated { viewsAwaitingConstraints() }
        }
        let text = lines.joined(separator: "\n")
        Log.crashes.error("Exception thrown: \(text, privacy: .public)")
        append("\(Date.now.ISO8601Format()) \(text)\n")
    }

    @MainActor
    private static func viewsAwaitingConstraints() -> [String] {
        var found: [String] = []
        for window in NSApp?.windows ?? [] {
            guard let root = window.contentView?.superview ?? window.contentView else { continue }
            collect(from: root, windowTitle: window.title, into: &found)
        }
        if found.isEmpty { return ["  no view is marked as needing a constraint update"] }
        guard found.count > maximumSuspects else { return found }
        return found.prefix(maximumSuspects) + ["  and \(found.count - maximumSuspects) more"]
    }

    /// Only the deepest marked views: marking a view marks its ancestors, and the offender is
    /// the end of that chain.
    @MainActor
    @discardableResult
    private static func collect(from view: NSView, windowTitle: String, into found: inout [String]) -> Bool {
        var markedBelow = false
        for child in view.subviews {
            let childMarked = collect(from: child, windowTitle: windowTitle, into: &found)
            markedBelow = markedBelow || childMarked
        }
        guard view.needsUpdateConstraints else { return markedBelow }
        if !markedBelow {
            let ancestry = sequence(first: view, next: \.superview)
                .map { String(describing: type(of: $0)) }
                .joined(separator: " < ")
            found.append("  needs constraints in \"\(windowTitle)\": \(ancestry)")
        }
        return true
    }

    /// Synchronous, because the process is usually about to trap and an async write would be lost.
    private static func append(_ line: String) {
        fileLock.withLock {
            let url = fileURL
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > maximumFileBytes { try FileManager.default.removeItem(at: url) }
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } catch {
                Log.crashes.error("Could not write the exception log: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
