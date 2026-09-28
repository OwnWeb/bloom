import Foundation

/// What macOS asked Bloom to open.
///
/// File URLs and custom-scheme URLs can both arrive through SwiftUI's `onOpenURL`, while AppKit
/// delivers them through two different application delegate callbacks. Classifying them before
/// either route acts is what stops a directory from being parsed as a malformed Bloom link.
public enum ApplicationOpenTarget: Hashable, Sendable {
    case projectDirectory(String)
    case deepLink(URL)

    public init(url: URL) {
        if url.isFileURL {
            // URL.path has already decoded spaces and other escaped path characters. Resolve
            // symlinks here so `repo`, `repo/.` and a symlink to `repo` share one event identity.
            self = .projectDirectory(FolderPath.resolved(url.path))
        } else {
            self = .deepLink(url)
        }
    }
}

/// Holds operating-system open events until the app model exists and admits each event once.
///
/// A cold launch can deliver an open-documents event before SwiftUI has created the main window.
/// Once the window exists, AppKit and SwiftUI can both deliver the same event. Active targets stay
/// claimed until their asynchronous work finishes, then remain in a short replay window so both
/// lifecycle paths cannot add the same project twice.
public struct ApplicationOpenInbox: Sendable {
    public static let replayInterval: TimeInterval = 2

    private var isConnected = false
    private var pending: [ApplicationOpenTarget] = []
    private var active: Set<ApplicationOpenTarget> = []
    private var recentlyFinished: [ApplicationOpenTarget: Date] = [:]

    public init() {}

    /// Receives an event. A returned target is claimed by the caller until `finish` is called.
    public mutating func receive(_ url: URL, at now: Date = .now) -> [ApplicationOpenTarget] {
        receive(ApplicationOpenTarget(url: url), at: now)
    }

    /// Makes queued launch events available once the app model can handle them.
    public mutating func connect(at now: Date = .now) -> [ApplicationOpenTarget] {
        isConnected = true
        prune(at: now)

        let queued = pending
        pending = []
        var admitted: [ApplicationOpenTarget] = []
        for target in queued where mayAdmit(target, at: now) {
            active.insert(target)
            admitted.append(target)
        }
        return admitted
    }

    /// Releases an admitted target while retaining enough history to drop a second framework's
    /// delivery of the same operating-system event.
    public mutating func finish(_ target: ApplicationOpenTarget, at now: Date = .now) {
        guard active.remove(target) != nil else { return }
        recentlyFinished[target] = now
        prune(at: now)
    }

    private mutating func receive(
        _ target: ApplicationOpenTarget,
        at now: Date
    ) -> [ApplicationOpenTarget] {
        prune(at: now)
        guard isConnected else {
            if !pending.contains(target) { pending.append(target) }
            return []
        }
        guard mayAdmit(target, at: now) else { return [] }
        active.insert(target)
        return [target]
    }

    private func mayAdmit(_ target: ApplicationOpenTarget, at now: Date) -> Bool {
        guard !active.contains(target) else { return false }
        guard let finished = recentlyFinished[target] else { return true }
        return now.timeIntervalSince(finished) >= Self.replayInterval
    }

    private mutating func prune(at now: Date) {
        recentlyFinished = recentlyFinished.filter {
            now.timeIntervalSince($0.value) < Self.replayInterval
        }
    }
}
