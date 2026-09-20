import Foundation

public struct ProjectIconRequestPoll: Sendable, Equatable {
    public var projectIcon: MachineConfiguration.ProjectIcon?
    public var pollAfter: Duration

    public init(projectIcon: MachineConfiguration.ProjectIcon?, pollAfter: Duration) {
        self.projectIcon = projectIcon
        self.pollAfter = pollAfter
    }
}

public struct ProjectIconRequestUnavailable: Error, Sendable, Equatable {
    public var retryAfter: Duration

    public init(retryAfter: Duration) {
        self.retryAfter = retryAfter
    }
}

extension RunbloomClient {
    /// Reloads the server-authored request for this authenticated machine. There is deliberately no
    /// parameter: the workspace secret and URL path are the only authority.
    public func projectIconRequest() async throws -> ProjectIconRequestPoll {
        struct Answer: Decodable {
            var projectIcon: MachineConfiguration.ProjectIcon?
            var pollAfterSeconds: Int

            enum CodingKeys: String, CodingKey {
                case projectIcon = "project_icon"
                case pollAfterSeconds = "poll_after_seconds"
            }
        }

        let response = try await sendResponse(.GET, "/project-icon-request", expecting: [200, 503])
        if response.status == 503 {
            struct Refusal: Decodable { var code: String }
            let refusal = try? decode(Refusal.self, response.body, status: 503)
            guard refusal?.code == "project_icon_request_unavailable" else {
                throw RunbloomError.unreachable("runbloom.app answered 503.")
            }
            let seconds = response.retryAfter.flatMap(Int.init) ?? 60
            throw ProjectIconRequestUnavailable(retryAfter: .seconds(min(max(seconds, 1), 300)))
        }

        let answer = try decode(Answer.self, response.body, status: 200)
        guard (1...86_400).contains(answer.pollAfterSeconds) else {
            throw RunbloomError.unexpected(status: 200)
        }
        if let projectIcon = answer.projectIcon {
            guard projectIcon.hasValidIdentity, projectIcon.shouldDiscover != nil else {
                throw RunbloomError.unexpected(status: 200)
            }
        }
        return ProjectIconRequestPoll(
            projectIcon: answer.projectIcon,
            pollAfter: .seconds(answer.pollAfterSeconds)
        )
    }

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
