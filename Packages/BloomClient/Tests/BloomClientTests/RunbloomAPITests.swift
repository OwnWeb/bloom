@testable import BloomClient
import Foundation
import Testing

/// runbloom.app's client API, against answers shaped the way its design document and its builder
/// describe them.
@Suite struct RunbloomAPITests {
    @Test func readsTheAccountWithTeamsAndAgentKeys() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/me", .json("""
        {"data": {"id": "01k5user", "name": "Freek", "email": "freek@spatie.be", "avatar_url": null, "current_team_id": "01k5team",
          "github_connected": true,
          "agent_keys": [{"team_id": "01k5team", "agent": "claude", "team_key": true, "personal_key": false},
                         {"team_id": "01k5team", "agent": "codex", "team_key": false, "personal_key": false}],
          "teams": [{"id": "01k5team", "name": "Spatie", "slug": "spatie", "role": "owner", "cloud_workspaces_enabled": true},
                    {"id": "01k5other", "name": "Side", "slug": "side", "role": "member", "cloud_workspaces_enabled": false}]}}
        """))
        let account = try await Fixtures.api(transport).account()
        #expect(account.name == "Freek")
        #expect(account.githubConnected)
        #expect(account.cloudTeams.map(\.id) == ["01k5team"])
        #expect(account.hasAgentKey(team: "01k5team", agent: "claude"))
        #expect(!account.hasAgentKey(team: "01k5team", agent: "codex"))
        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
        #expect(request.url?.absoluteString == "https://runbloom.test/api/v1/me")
    }

    @Test func listsCloudWorkspacesWithTheirSummaries() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/teams/01k5team/cloud-workspaces", .json("""
        {"data": [{"id": "01k5ws", "team_id": "01k5team", "name": "Queue retries", "project": {"id": "01k5proj", "repository": "spatie/bloom"},
          "branch": "freek/queue-retries", "base_branch": "main", "state": "waiting_for_input", "shared_with_team": false,
          "owner": {"id": "01k5user", "name": "Freek", "avatar_url": null}, "role": "owner", "can_open": true, "can_archive": true,
          "unread": true, "created_at": "2026-09-17T09:40:02.000000Z", "archived_at": null,
          "summary": {"revision": 42, "observed_at": "2026-09-17T10:00:00Z", "title": "Retry the queue", "branch": "freek/queue-retries",
            "state": "waiting_for_input", "awake": false, "setup": {"state": "succeeded", "step": null},
            "last_message": {"chat_id": "c1", "author_kind": "agent", "author_user_id": null, "excerpt": "Should it retry?", "at": "2026-09-17T09:59:00.123456Z"},
            "waiting": {"kind": "question", "chat_id": "c1", "since": "2026-09-17T09:59:00Z"},
            "diff": {"files": 4, "additions": 120, "deletions": 8}, "pull_request": null, "chats": [], "present_user_ids": ["01k5user"],
            "bloom_server_version": "0.9.0"}},
         {"id": "01k5new", "team_id": "01k5team", "name": "Fresh", "branch": "freek/fresh", "base_branch": "main", "state": "setting_up",
          "role": "owner", "summary": null}]}
        """))
        let items = try await Fixtures.api(transport).cloudWorkspaces(team: "01k5team")
        #expect(items.count == 2)
        let first = items[0]
        #expect(first.displayName == "Retry the queue")
        #expect(first.summary?.waiting?.kind == "question")
        #expect(first.summary?.diff == .init(files: 4, additions: 120, deletions: 8))
        #expect(first.summary?.lastMessage?.at != nil)
        #expect(first.createdAt != nil)
        #expect(!first.isAwake)
        #expect(items[1].summary == nil)
        #expect(items[1].displayName == "Fresh")
    }

    @Test func aSummaryItCannotReadIsNoSummaryRatherThanAFailedList() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/cloud-workspaces/01k5ws", .json("""
        {"data": {"id": "01k5ws", "team_id": "t", "name": "Odd", "branch": "b", "state": "idle", "role": "owner", "summary": "not an object"}}
        """))
        let item = try await Fixtures.api(transport).cloudWorkspace("01k5ws")
        #expect(item.summary == nil)
        #expect(item.name == "Odd")
    }

    @Test func createsACloudWorkspace() async throws {
        let transport = FakeTransport()
        transport.on("POST", "/teams/01k5team/cloud-workspaces", .json("""
        {"data": {"id": "01k5ws", "team_id": "01k5team", "name": "Queue retries", "branch": "freek/queue-retries", "base_branch": "main", "state": "setting_up", "role": "owner"}}
        """, status: 201))
        let item = try await Fixtures.api(transport).createCloudWorkspace(
            team: "01k5team", request: CreateCloudWorkspace(project: "01k5proj", name: "Queue retries", branch: "freek/queue-retries")
        )
        #expect(item.state == "setting_up")
        let body = try #require(transport.requests.first?.httpBody)
        let sent = try JSONSerialization.jsonObject(with: body) as? [String: String]
        #expect(sent == ["project": "01k5proj", "name": "Queue retries", "branch": "freek/queue-retries"])
    }

    @Test func readsASessionToken() async throws {
        let transport = FakeTransport()
        transport.on("POST", "/session-token", .json(Fixtures.sessionToken(awake: false)))
        let token = try await Fixtures.api(transport).sessionToken(for: "01k5ws")
        #expect(token.token == "session-1")
        #expect(!token.awake)
        #expect(token.allows("share"))
        #expect(token.machineURL.absoluteString == Fixtures.machine)
    }

    @Test func readsAPreviewToken() async throws {
        let transport = FakeTransport()
        transport.on("POST", "/preview-token", .json("""
        {"data": {"token": "p", "expires_at": "2026-09-17T10:01:00Z", "enter_url": "https://bloom-01k5machine.sprites.test/_bloom/preview/enter?token=p"}}
        """))
        let preview = try await Fixtures.api(transport).previewToken(for: "01k5ws")
        #expect(preview.enterURL.query() == "token=p")
    }

    @Test func machineNotReadyIsReadWithItsRetry() async throws {
        let transport = FakeTransport()
        transport.on("POST", "/session-token", .json(#"{"code": "machine_not_ready", "message": "This Cloud workspace is still starting.", "retry_after": 5}"#, status: 409))
        await #expect(throws: RunbloomRefusal(status: 409, code: "machine_not_ready", message: "This Cloud workspace is still starting.", retryAfter: 5)) {
            try await Fixtures.api(transport).sessionToken(for: "01k5ws")
        }
    }

    @Test func aLimitRefusalCarriesItsLimit() async throws {
        let transport = FakeTransport()
        transport.on("POST", "/session-token", .json(
            #"{"code": "limit_reached", "limit": "concurrent_machines", "message": "Your team already has 20 Cloud workspaces running.", "retry_after": 60}"#, status: 429
        ))
        do {
            _ = try await Fixtures.api(transport).sessionToken(for: "01k5ws")
            Issue.record("Expected a refusal")
        } catch let refusal as RunbloomRefusal {
            #expect(refusal.isLimit)
            let notice = try #require(LimitNotice(refusal: refusal))
            #expect(notice.kind == .waiting)
            #expect(notice.message == "Your team already has 20 Cloud workspaces running.")
        }
    }

    @Test func aRefusedAccessTokenIsTriedOnceMoreWithAFreshOne() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/me",
                     .json(#"{"code": "unauthenticated", "message": "Unauthenticated."}"#, status: 401),
                     .json(#"{"data": {"id": "u", "name": "Freek", "email": "f@s.be", "teams": []}}"#))
        let tokens = TokenLog()
        let account = try await Fixtures.api(transport, tokens: tokens).account()
        #expect(account.id == "u")
        #expect(tokens.forced == [false, true])
        #expect(transport.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-access")
    }

    @Test func anErrorPageStillReadsAsARefusal() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/me", .init(status: 502, body: Data("<html>Bad gateway</html>".utf8)))
        do {
            _ = try await Fixtures.api(transport).account()
            Issue.record("Expected a refusal")
        } catch let refusal as RunbloomRefusal {
            #expect(refusal.status == 502)
            #expect(refusal.code == "server_error")
        }
    }

    @Test func sharingReadsMembersAndShares() async throws {
        let transport = FakeTransport()
        transport.on("POST", "/cloud-workspaces/01k5ws/members", .json("""
        {"data": {"shared_with_team": true, "members": [{"user": {"id": "u1", "name": "Freek", "avatar_url": null}, "role": "owner"}]}}
        """))
        transport.on("POST", "/cloud-workspaces/01k5ws/shares", .json("""
        {"data": {"id": "s1", "url": "https://runbloom.app/share/s1", "created_at": "2026-09-17T10:00:00.000000Z", "expires_at": "2026-09-24T10:00:00.000000Z", "created_by": {"id": "u1", "name": "Freek"}}}
        """, status: 201))
        transport.on("DELETE", "/cloud-workspaces/01k5ws/members/u2", .noContent())
        let api = Fixtures.api(transport)
        let members = try await api.shareWithTeam(true, workspace: "01k5ws")
        #expect(members.isShared)
        let share = try await api.createShare(for: "01k5ws")
        #expect(share.url.absoluteString == "https://runbloom.app/share/s1")
        try await api.removeCollaborator("u2", from: "01k5ws")
        let body = try #require(transport.requests.first?.httpBody)
        #expect(String(decoding: body, as: UTF8.self) == #"{"shared_with_team":true}"#)
    }
}

@Suite struct RunbloomEnvironmentTests {
    @Test func bloomDevSignsInWithItsOwnScheme() {
        let dev = RunbloomEnvironment.resolve(environment: [:], setting: nil, urlSchemes: ["bloomdev"])
        #expect(dev.redirect == "bloomdev://oauth/callback")
        #expect(dev.origin == RunbloomEnvironment.productionOrigin)
        let installed = RunbloomEnvironment.resolve(environment: [:], setting: nil, urlSchemes: ["bloom"])
        #expect(installed.redirect == "bloom://oauth/callback")
    }

    @Test func aDevelopmentServerIsTakenOnlyAsAnOrigin() {
        let tunnel = RunbloomEnvironment.resolve(environment: ["BLOOM_RUNBLOOM_URL": "https://freek.tunnel.test/some/path?x=1"], setting: nil, urlSchemes: [])
        #expect(tunnel.origin.absoluteString == "https://freek.tunnel.test")
        let plain = RunbloomEnvironment.resolve(environment: [:], setting: "http://example.com", urlSchemes: [])
        #expect(plain.origin == RunbloomEnvironment.productionOrigin)
        let loopback = RunbloomEnvironment.resolve(environment: [:], setting: "http://localhost:8000", urlSchemes: [])
        #expect(loopback.origin.absoluteString == "http://localhost:8000")
    }

    @Test func aDiscoveryDocumentOnAnotherHostIsRefused() throws {
        let origin = URL(string: "https://runbloom.app")!
        let json = """
        {"issuer": "https://runbloom.app", "authorization_endpoint": "https://runbloom.app/oauth/authorize",
         "token_endpoint": "https://evil.test/oauth/token", "revocation_endpoint": "https://runbloom.app/oauth/revoke",
         "api_base_url": "https://runbloom.app/api/v1", "grant_types_supported": ["authorization_code"],
         "clients": {"mac": {"client_id": "01a0af16-6ab7-72c5-82e0-bd1f9484652a", "name": "Bloom for Mac", "redirect_uris": ["bloom://oauth/callback", "bloomdev://oauth/callback"]}}}
        """
        let document = try JSONDecoder().decode(BloomAuthDocument.self, from: Data(json.utf8))
        #expect(throws: RunbloomRefusal.self) { try document.validate(origin: origin) }
        let client = try document.macClient(redirect: "bloomdev://oauth/callback")
        #expect(client.clientID == "01a0af16-6ab7-72c5-82e0-bd1f9484652a")
        #expect(throws: RunbloomRefusal.self) { try document.macClient(redirect: "other://oauth/callback") }
    }
}

@Suite struct LimitNoticeTests {
    @Test(arguments: ["monthly_usage", "total_machines", "kill_switch", "something_new"])
    func everyLimitButConcurrentMachinesIsBlocked(limit: String) {
        #expect(LimitNotice(limit: limit, message: "Stop.").kind == .blocked)
    }

    @Test func runbloomsSentenceIsKeptAndAnEmptyOneGetsOne() {
        #expect(LimitNotice(limit: "concurrent_machines", message: "  Wait.  ").message == "Wait.")
        #expect(!LimitNotice(limit: "monthly_usage", message: "").message.isEmpty)
    }
}
