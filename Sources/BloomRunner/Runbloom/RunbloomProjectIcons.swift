import Foundation

extension RunbloomClient {
    /// Records one revisioned discovery answer. An explicit null icon resolves the request to the
    /// initials fallback; making no call means the authority never asked this machine to look.
    public func reportProjectIcon(_ report: ProjectIconReport) async throws {
        let icon: Any
        if let data = report.icon, let sha256 = report.iconSHA256 {
            icon = ["data": data.base64EncodedString(), "sha256": sha256]
        } else {
            icon = NSNull()
        }
        let body: [String: Any] = [
            "requested_revision": report.requestedRevision,
            "detector_version": report.detectorVersion,
            "source_commit": report.sourceCommit,
            "icon": icon,
        ]
        _ = try await send(
            .PUT,
            "/project-icon",
            body: JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
            expecting: [204]
        )
    }
}
