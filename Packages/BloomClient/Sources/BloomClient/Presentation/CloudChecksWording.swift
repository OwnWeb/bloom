import Foundation

/// The sentences a Cloud workspace's pull request and checks are said in, kept apart from the
/// records so a test can reach them.
///
/// The counts are runbloom.app's and arrive spelled two ways for the same idea: the pull request
/// carries `passed` and the checks endpoint carries `succeeded`. Both are read here rather than in
/// a view, so the wart is in one place and neither body is bent into the other's shape.
public enum CloudChecksWording {
    /// What the band says about the checks, in the same voice `gh` puts it to a local workspace:
    /// "3 checks passed", "1 of 4 failing", "2 queued".
    public static func summary(_ rollup: CloudChecksRollup?) -> String {
        guard let rollup, rollup.total > 0 else { return "" }
        if rollup.failed > 0 { return "\(rollup.failed) of \(rollup.total) failing" }
        if rollup.pending > 0 { return "\(rollup.pending) queued" }
        return rollup.passed == 1 ? "1 check passed" : "\(rollup.passed) checks passed"
    }

    /// The same from the checks endpoint's own summary, which spells the passing count differently.
    public static func summary(_ summary: CloudChecksSummary) -> String {
        Self.summary(CloudChecksRollup(
            total: summary.total, passed: summary.succeeded, failed: summary.failed, pending: summary.pending
        ))
    }

    /// How old the answer is, for the line that stops the band implying it is live. Nil for an
    /// answer fresh enough that saying so would be noise.
    ///
    /// runbloom.app refreshes on a schedule every minute, so "just now" covers the common case and
    /// only a genuinely old or stale answer earns a sentence.
    public static func freshness(fetchedAt: Date?, isStale: Bool, now: Date = Date()) -> String? {
        guard let fetchedAt else { return isStale ? "GitHub has not been asked about this branch yet." : nil }
        let age = now.timeIntervalSince(fetchedAt)
        guard isStale || age >= 120 else { return nil }
        let minutes = Int((age / 60).rounded())
        if minutes < 1 { return "Last checked with GitHub a moment ago." }
        if minutes == 1 { return "Last checked with GitHub a minute ago." }
        if minutes < 60 { return "Last checked with GitHub \(minutes) minutes ago." }
        let hours = minutes / 60
        return hours == 1 ? "Last checked with GitHub an hour ago." : "Last checked with GitHub \(hours) hours ago."
    }
}
