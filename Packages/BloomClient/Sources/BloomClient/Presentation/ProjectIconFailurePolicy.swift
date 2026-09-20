/// Whether another normal Cloud poll may retry a failed project artwork read.
///
/// An immutable revision that is absent, forbidden, malformed or outside the authorised API will
/// not become usable by repeating it. Transport failures, server failures, request timeouts and
/// throttling can, so those stay retryable.
public enum ProjectIconFailurePolicy {
    public static func shouldRetry(_ error: any Error) -> Bool {
        guard let refusal = error as? RunbloomRefusal else { return true }
        if refusal.code == "unreadable_project_icon" || refusal.status == 0 { return false }
        if refusal.status == 408 || refusal.status == 429 || refusal.status >= 500 { return true }
        return false
    }
}
