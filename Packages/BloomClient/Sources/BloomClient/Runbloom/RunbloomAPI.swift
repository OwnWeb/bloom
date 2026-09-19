import Foundation

/// runbloom.app's client API, `/api/v1`, for one signed in person.
///
/// It holds no tokens. It asks `accessToken` for one on every call, which is the sign in's
/// business: refreshing a token that ran out, and knowing when there is no sign in at all. A 401 is
/// retried once with a token the sign in was told to refresh, because an access token lives an hour
/// and a Mac that slept through its expiry sends one stale request before anything else notices.
public struct RunbloomAPI: Sendable {
    /// Hands out an access token. `true` asks for a fresh one even if the current one looks valid.
    public typealias AccessToken = @Sendable (_ forceRefresh: Bool) async throws -> String

    public let baseURL: URL
    let transport: any HTTPTransport
    let accessToken: AccessToken

    /// - Parameter baseURL: the API root, `https://runbloom.app/api/v1`, as `/.well-known/bloom-auth`
    ///   names it in `api_base_url`.
    public init(baseURL: URL, transport: any HTTPTransport = URLSessionTransport(), accessToken: @escaping AccessToken) {
        self.baseURL = baseURL
        self.transport = transport
        self.accessToken = accessToken
    }

    // MARK: Account

    public func account() async throws -> RunbloomAccount {
        try await get("me")
    }

    public func projects(team: String) async throws -> [RunbloomProject] {
        try await get("teams/\(team)/projects")
    }

    public func teamMembers(team: String) async throws -> [RunbloomPerson] {
        try await get("teams/\(team)/members")
    }

    // MARK: Cloud workspaces

    /// The team's Cloud workspaces, newest first, without archived ones. Never wakes a machine.
    public func cloudWorkspaces(team: String) async throws -> [CloudWorkspaceItem] {
        try await get("teams/\(team)/cloud-workspaces")
    }

    public func cloudWorkspace(_ id: String) async throws -> CloudWorkspaceItem {
        try await get("cloud-workspaces/\(id)")
    }

    /// Creates a Cloud workspace. Setting up its machine starts on runbloom.app's side and is
    /// followed from the list; the answer is the workspace in `setting_up`.
    public func createCloudWorkspace(team: String, request: CreateCloudWorkspace) async throws -> CloudWorkspaceItem {
        try await send("POST", "teams/\(team)/cloud-workspaces", body: request)
    }

    /// Archives: runbloom.app revokes the machine's secret and deletes the machine, and with it the
    /// conversation. Never refused by a limit.
    public func archiveCloudWorkspace(_ id: String) async throws {
        try await sendIgnoringBody("DELETE", "cloud-workspaces/\(id)")
    }

    public func markRead(_ id: String) async throws {
        try await sendIgnoringBody("POST", "cloud-workspaces/\(id)/read")
    }

    public func sessionToken(for id: String) async throws -> SessionToken {
        try await send("POST", "cloud-workspaces/\(id)/session-token", body: Empty())
    }

    public func previewToken(for id: String) async throws -> PreviewToken {
        try await send("POST", "cloud-workspaces/\(id)/preview-token", body: Empty())
    }

    // MARK: The pull request and its checks

    /// What GitHub last told runbloom.app about this workspace's branch. Cached on its side and
    /// refreshed on a schedule, so the answer carries when it was fetched and whether it is stale.
    public func pullRequest(for id: String) async throws -> CloudPullRequestState {
        try await get("cloud-workspaces/\(id)/pull-request")
    }

    public func checks(for id: String) async throws -> CloudChecks {
        try await get("cloud-workspaces/\(id)/checks")
    }

    /// The log of a failed check, trimmed on runbloom.app exactly as `CheckFailureHandoff` trims one
    /// here, for a Bloom Cloud workspace, where this Mac has no worktree to run `gh` in. `check` is
    /// the check's `id` from `checks(for:)`. Answered bare rather than in the resource envelope.
    public func checkLog(for id: String, check: String) async throws -> CloudCheckLog {
        let data = try await perform("GET", "cloud-workspaces/\(id)/checks/\(check)/log", body: nil)
        do {
            return try JSONDecoder().decode(CloudCheckLog.self, from: data)
        } catch {
            throw RunbloomRefusal(status: 200, code: "unreadable_answer", message: "runbloom.app answered in a way this version of Bloom cannot read. Check for an update.")
        }
    }

    /// One page of a project's branches for the create sheet's base branch list: the default first
    /// when it matches, then newest commit first, thirty a page from page 1, `search` a case
    /// insensitive substring. Read either bare or in the resource envelope, whichever it comes in.
    public func branches(team: String, project: String, search: String, page: Int) async throws -> CloudProjectBranches {
        let data = try await perform(
            "GET", "teams/\(team)/projects/\(project)/branches", body: nil,
            query: [URLQueryItem(name: "search", value: search), URLQueryItem(name: "page", value: String(page))]
        )
        if let wrapped = try? JSONDecoder().decode(Envelope<CloudProjectBranches>.self, from: data) { return wrapped.data }
        do {
            return try JSONDecoder().decode(CloudProjectBranches.self, from: data)
        } catch {
            throw RunbloomRefusal(status: 200, code: "unreadable_answer", message: "runbloom.app answered in a way this version of Bloom cannot read. Check for an update.")
        }
    }

    /// Takes the pull request out of draft, as the signed-in person rather than as the agent.
    public func markPullRequestReady(_ id: String) async throws -> CloudPullRequestState {
        try await send("POST", "cloud-workspaces/\(id)/pull-request/ready", body: Empty())
    }

    /// Merges it, as the signed-in person. Both of these answer the same body the read does, so a
    /// caller shows the outcome without asking again.
    public func mergePullRequest(_ id: String, request: CloudMergeRequest) async throws -> CloudPullRequestState {
        try await send("POST", "cloud-workspaces/\(id)/pull-request/merge", body: request)
    }

    // MARK: Sharing

    public func members(of id: String) async throws -> CloudWorkspaceMembers {
        try await get("cloud-workspaces/\(id)/members")
    }

    public func addCollaborator(_ userID: String, to id: String) async throws -> CloudWorkspaceMembers {
        struct Body: Encodable {
            var userID: String
            enum CodingKeys: String, CodingKey { case userID = "user_id" }
        }
        return try await send("POST", "cloud-workspaces/\(id)/members", body: Body(userID: userID))
    }

    public func shareWithTeam(_ shared: Bool, workspace id: String) async throws -> CloudWorkspaceMembers {
        struct Body: Encodable {
            var sharedWithTeam: Bool
            enum CodingKeys: String, CodingKey { case sharedWithTeam = "shared_with_team" }
        }
        return try await send("POST", "cloud-workspaces/\(id)/members", body: Body(sharedWithTeam: shared))
    }

    /// Removes a collaborator. runbloom.app also cancels their queued prompts, ends their running
    /// turns and closes their connections to the machine.
    public func removeCollaborator(_ userID: String, from id: String) async throws {
        try await sendIgnoringBody("DELETE", "cloud-workspaces/\(id)/members/\(userID)")
    }

    public func shares(of id: String) async throws -> [PreviewShare] {
        try await get("cloud-workspaces/\(id)/shares")
    }

    public func createShare(for id: String) async throws -> PreviewShare {
        try await send("POST", "cloud-workspaces/\(id)/shares", body: Empty())
    }

    public func revokeShare(_ shareID: String, of id: String) async throws {
        try await sendIgnoringBody("DELETE", "cloud-workspaces/\(id)/shares/\(shareID)")
    }

    // MARK: Plumbing

    struct Empty: Codable {}

    /// Laravel's resource envelope, which every answer here but a 204 is wrapped in.
    struct Envelope<Value: Decodable>: Decodable {
        var data: Value
    }

    private func get<Value: Decodable>(_ path: String) async throws -> Value {
        let data = try await perform("GET", path, body: nil)
        return try Self.decode(Value.self, from: data)
    }

    private func send<Value: Decodable>(_ method: String, _ path: String, body: some Encodable) async throws -> Value {
        let data = try await perform(method, path, body: try JSONEncoder().encode(body))
        return try Self.decode(Value.self, from: data)
    }

    private func sendIgnoringBody(_ method: String, _ path: String) async throws {
        _ = try await perform(method, path, body: nil)
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(Envelope<Value>.self, from: data).data
        } catch {
            throw RunbloomRefusal(status: 200, code: "unreadable_answer", message: "runbloom.app answered in a way this version of Bloom cannot read. Check for an update.")
        }
    }

    private func perform(_ method: String, _ path: String, body: Data?, query: [URLQueryItem] = []) async throws -> Data {
        let first = try await request(method, path, body: body, query: query, token: try await accessToken(false))
        if first.1.statusCode == 401 {
            let second = try await request(method, path, body: body, query: query, token: try await accessToken(true))
            return try Self.check(second)
        }
        return try Self.check(first)
    }

    private func request(
        _ method: String, _ path: String, body: Data?, query: [URLQueryItem] = [], token: String
    ) async throws -> (Data, HTTPURLResponse) {
        // Query items appended as items, never written into `path`: `appending(path:)` would
        // encode the `?` as part of the path.
        var url = baseURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await transport.data(for: request)
    }

    private static func check(_ answer: (Data, HTTPURLResponse)) throws -> Data {
        let (data, response) = answer
        guard (200..<300).contains(response.statusCode) else {
            throw RunbloomRefusal.from(status: response.statusCode, body: data)
        }
        return data
    }
}

/// The body of `POST /api/v1/teams/{team}/cloud-workspaces`.
public struct CreateCloudWorkspace: Codable, Sendable, Hashable {
    /// The project's id, not its repository name.
    public var project: String
    public var name: String
    public var branch: String
    /// Nil takes the project's default branch.
    public var baseBranch: String?
    /// Whether the machine runs the project's setup at all.
    ///
    /// **Nil, and therefore absent from the body, means it does**, which is what every caller
    /// before this field meant and what the server does with a body that does not carry it. Only a
    /// person who unticks the box in the create window sends anything, and what they send is
    /// `false`: a workspace that is usable the moment it is cloned, whose setup record is
    /// `skipped` rather than pending, and which nothing waits for. `run_setup` over RPC still runs
    /// it later, because "not now" and "never" are different answers.
    public var runSetup: Bool?

    public init(project: String, name: String, branch: String, baseBranch: String? = nil, runSetup: Bool? = nil) {
        self.project = project
        self.name = name
        self.branch = branch
        self.baseBranch = baseBranch
        self.runSetup = runSetup
    }

    enum CodingKeys: String, CodingKey {
        case project, name, branch
        case baseBranch = "base_branch"
        case runSetup = "run_setup"
    }
}
