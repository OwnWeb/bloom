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

    @Test func aWorkspaceTheReaderCannotOpenIsListedWithWhatItCarries() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/teams/t/cloud-workspaces", .json("""
        {"data": [{"id": "01k5private", "team_id": "t", "name": "Somebody's", "state": "idle",
          "owner": {"id": "u9", "name": "Alex", "avatar_url": null}, "role": null, "can_open": false, "can_archive": true,
          "created_at": "2026-09-17T09:40:02.000000Z", "archived_at": null}]}
        """))
        let item = try #require(try await Fixtures.api(transport).cloudWorkspaces(team: "t").first)
        #expect(!item.canOpen)
        #expect(item.canArchive)
        #expect(!item.isMember)
        #expect(item.summary == nil)
        #expect(item.branch == "")
        #expect(CloudWorkspaceStatus(item: item) == .asleep)
    }

    @Test func pushAccessIsTrueFalseOrNotKnown() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/cloud-workspaces/w/members", .json("""
        {"data": {"shared_with_team": false, "members": [
          {"user": {"id": "a", "name": "A"}, "role": "owner", "push_access": true},
          {"user": {"id": "b", "name": "B"}, "role": "collaborator", "push_access": false},
          {"user": {"id": "c", "name": "C"}, "role": "collaborator", "push_access": null},
          {"user": {"id": "d", "name": "D"}, "role": "collaborator"}]}}
        """))
        transport.on("GET", "/cloud-workspaces/w/shares", .json("""
        {"data": [{"id": "s", "url": "https://runbloom.app/share/s", "created_at": null, "expires_at": "2026-09-24T10:00:00Z", "created_by": null}]}
        """))
        let api = Fixtures.api(transport)
        let members = try await api.members(of: "w")
        #expect(members.members.map(\.hasPushAccess) == [true, false, nil, nil])
        let shares = try await api.shares(of: "w")
        #expect(shares.first?.createdBy == nil)
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

    @Test func changesAndClearsAPersonalWorkspaceColourAtTheSuppliedEndpoint() async throws {
        let transport = FakeTransport()
        let endpoint = "https://runbloom.test/api/v1/cloud-workspaces/01k5ws/mark"
        transport.on(
            "PUT", "/cloud-workspaces/01k5ws/mark",
            .json("""
            {"data":{"id":"01k5ws","state":"idle","colour":"4C8DF6","can_colour":true,
             "colour_url":"\(endpoint)"}}
            """),
            .json("""
            {"data":{"id":"01k5ws","state":"idle","colour":null,"can_colour":true,
             "colour_url":"\(endpoint)"}}
            """)
        )
        let api = Fixtures.api(transport)

        let marked = try await api.updateCloudWorkspaceColour("4C8DF6", at: endpoint)
        let cleared = try await api.updateCloudWorkspaceColour(nil, at: endpoint)

        #expect(marked.colour == "4C8DF6")
        #expect(cleared.colour == nil)
        #expect(transport.requests.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) }
            == [#"{"colour":"4C8DF6"}"#, #"{"colour":null}"#])
    }

    @Test func readsAndRefreshesProjectIconStateOnlyAtSuppliedAPIEndpoints() async throws {
        let transport = FakeTransport()
        let settings = "https://runbloom.test/api/v1/teams/t/projects/p/settings"
        let refresh = "https://runbloom.test/api/v1/teams/t/projects/p/icon-refreshes"
        let icon = "https://runbloom.test/api/v1/teams/t/projects/p/icon/4"
        transport.on("GET", "/teams/t/projects/p/settings", .json("""
        {"data":{"id":"p","repository":"spatie/bloom","icon_url":"\(icon)",
         "icon":{"status":"available","checked_at":"2026-09-20T04:00:00Z","refresh_url":"\(refresh)"}}}
        """))
        transport.on("POST", "/teams/t/projects/p/icon-refreshes", .json("""
        {"data":{"id":"p","repository":"spatie/bloom","icon_url":"\(icon)",
         "icon":{"status":"pending","checked_at":"2026-09-20T04:00:00Z","refresh_url":"\(refresh)"}}}
        """))
        let api = Fixtures.api(transport)

        let current = try await api.projectSettings(at: settings)
        let requested = try await api.refreshProjectIcon(at: try #require(current.icon.refreshURL))

        #expect(current.icon.status == "available")
        #expect(current.iconURL == icon)
        #expect(requested.icon.status == "pending")
        #expect(transport.requests.map(\.url?.absoluteString) == [settings, refresh])
    }

    @Test func downloadsAProjectIconWithBearerAuthenticationAndPNGAccept() async throws {
        let transport = FakeTransport()
        let endpoint = "https://runbloom.test/api/v1/teams/t/projects/p/icon/9"
        let png = Data([0x89, 0x50, 0x4e, 0x47])
        transport.on("GET", "/teams/t/projects/p/icon/9", .init(
            status: 200, body: png, headers: ["Content-Type": "image/png", "Cache-Control": "private, immutable"]
        ))

        #expect(try await Fixtures.api(transport).projectIcon(at: endpoint) == png)
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == endpoint)
        #expect(request.value(forHTTPHeaderField: "Accept") == "image/png")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
    }

    @Test func aWithheldRefreshAndMissingIconRemainValidProjectSettings() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/teams/t/projects/p/settings", .json("""
        {"data":{"id":"p","repository":"spatie/bloom","icon_url":null,
         "icon":{"status":"missing","checked_at":null,"refresh_url":null}}}
        """))

        let settings = try await Fixtures.api(transport).projectSettings(
            at: "https://runbloom.test/api/v1/teams/t/projects/p/settings"
        )
        #expect(settings.iconURL == nil)
        #expect(settings.icon.status == "missing")
        #expect(settings.icon.refreshURL == nil)
    }

    @Test func aStaleIconRevisionDoesNotChangeTheReplacementAddress() async throws {
        let transport = FakeTransport()
        let old = "https://runbloom.test/api/v1/teams/t/projects/p/icon/4"
        let replacement = "https://runbloom.test/api/v1/teams/t/projects/p/icon/5"
        transport.on("GET", "/teams/t/projects/p/icon/4", .json(
            #"{"code":"not_found","message":"Not found."}"#, status: 404
        ))
        transport.on("GET", "/teams/t/projects/p/icon/5", .init(
            status: 200, body: Data([0x89, 0x50, 0x4e, 0x47]), headers: ["Content-Type": "image/png"]
        ))
        let api = Fixtures.api(transport)

        await #expect(throws: RunbloomRefusal.self) { try await api.projectIcon(at: old) }
        #expect(try await api.projectIcon(at: replacement) == Data([0x89, 0x50, 0x4e, 0x47]))
        #expect(transport.requests.map(\.url?.absoluteString) == [old, replacement])
    }

    @Test func refusesArbitraryOrBrokenProjectIconAddresses() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/teams/t/projects/p/icon/1", .json("{}"))
        let api = Fixtures.api(transport)

        for endpoint in [
            "https://elsewhere.test/api/v1/teams/t/projects/p/icon/1",
            "https://user:secret@runbloom.test/api/v1/teams/t/projects/p/icon/1",
            "https://runbloom.test/outside/icon.png",
            "/teams/t/projects/p/icon/1",
        ] {
            #expect(!api.allowsAPIEndpoint(endpoint))
            await #expect(throws: RunbloomRefusal.self) { try await api.projectIcon(at: endpoint) }
        }
        #expect(api.allowsAPIEndpoint("https://runbloom.test/api/v1/teams/t/projects/p/icon/1"))
        await #expect(throws: RunbloomRefusal.self) {
            try await api.projectIcon(at: "https://runbloom.test/api/v1/teams/t/projects/p/icon/1")
        }
    }

    @Test func projectListsDecodeMissingAndMalformedIconsCompatibly() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/teams/t/projects", .json("""
        {"data":[
          {"id":"one","repository":"spatie/one","default_branch":"main",
           "icon_url":"https://runbloom.test/api/v1/teams/t/projects/one/icon/2"},
          {"id":"two","repository":"spatie/two","default_branch":"main"},
          {"id":"three","repository":"spatie/three","default_branch":"main","icon_url":{"bad":true}},
          {"id":"four","repository":"spatie/four","default_branch":"main","icon_url":null}
        ]}
        """))

        let projects = try await Fixtures.api(transport).projects(team: "t")
        #expect(projects.map(\.iconURL) == [
            "https://runbloom.test/api/v1/teams/t/projects/one/icon/2", nil, nil, nil,
        ])
    }

    @Test func refusesAWorkspaceColourEndpointOutsideTheSignedInAPI() async {
        let api = Fixtures.api(FakeTransport())
        await #expect(throws: RunbloomRefusal.self) {
            try await api.updateCloudWorkspaceColour("4C8DF6", at: "https://elsewhere.test/api/v1/cloud-workspaces/w/mark")
        }
    }

    @Test func readsASessionToken() async throws {
        let transport = FakeTransport()
        transport.on("POST", "/session-token", .json(Fixtures.sessionToken(awake: false)))
        let token = try await Fixtures.api(transport).sessionToken(for: "01k5ws")
        #expect(token.token == "session-1")
        #expect(!token.awake)
        #expect(token.allows("share"))
        #expect(token.machineURL.absoluteString == Fixtures.machine)
        // The fixture predates the field, which is the case an older control server is in: absent
        // reads as nil rather than throwing, and the account is what the client falls back to.
        #expect(token.userID == nil)
    }

    /// The id a client tells its own messages by before it has an account object. It is the
    /// token's own `sub`, pinned to it by a test on runbloom.app's side, which is what makes
    /// reading the field rather than decoding the token correct as well as cheap. See
    /// `SessionToken.userID`.
    @Test func aSessionTokenSaysWhoItWasMintedFor() async throws {
        let transport = FakeTransport()
        transport.on("POST", "/session-token", .json("""
        {"data": {"token": "session-1", "expires_at": "2099-01-01T00:00:00.000000Z", \
        "machine_url": "\(Fixtures.machine)", "awake": true, "abilities": ["view"], \
        "user_id": "01k5user"}}
        """))
        let token = try await Fixtures.api(transport).sessionToken(for: "01k5ws")
        #expect(token.userID == "01k5user")
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
        let cloud = RunbloomEnvironment.resolve(environment: [:], setting: nil, urlSchemes: ["bloomcloud"])
        #expect(cloud.redirect == "bloomcloud://oauth/callback")
        #expect(cloud.origin == RunbloomEnvironment.productionOrigin)
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
    // MARK: The pull request and its checks

    @Test func readsAPullRequestWithEverythingTheBandDraws() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/cloud-workspaces/01k5ws/pull-request", .json("""
        {"data": {"has_pull_request": true, "number": 298, "url": "https://github.com/spatie/bloom/pull/298",
          "title": "Cloud workspaces: the Mac client", "state": "open", "is_draft": false, "mergeable": null,
          "mergeable_state": "blocked", "conflicts": false, "review_decision": "REVIEW_REQUIRED",
          "merge_blockers": ["Waiting for a review."], "base_branch": "main", "head_branch": "freek/cloud",
          "head_sha": "0123456789abcdef", "merge_methods": ["squash", "rebase"],
          "checks": {"total": 4, "passed": 3, "failed": 0, "pending": 1, "conclusion": null},
          "additions": 900, "deletions": 40, "changed_files": 21, "commits": 9,
          "updated_at": "2026-09-18T00:10:00.000000Z", "fetched_at": "2026-09-18T00:11:00.000000Z",
          "stale": false, "can_merge": false}}
        """))
        let state = try await Fixtures.api(transport).pullRequest(for: "01k5ws")
        #expect(state.hasPullRequest)
        #expect(state.number == 298)
        #expect(state.mergeable == nil, "null is not known yet, and must not read as false")
        #expect(state.conflicts == false)
        #expect(state.mergeBlockers == ["Waiting for a review."])
        #expect(state.mergeMethods == ["squash", "rebase"])
        #expect(state.checks?.pending == 1)
        #expect(state.canMerge == false)
        #expect(state.fetchedAt != nil)
        #expect(state.headSHA == "0123456789abcdef")
    }

    @Test func aBranchWithNoPullRequestIsThreeFieldsAndNotAFailure() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/cloud-workspaces/01k5ws/pull-request", .json("""
        {"data": {"has_pull_request": false, "head_branch": "freek/cloud", "base_branch": "main",
          "fetched_at": "2026-09-18T00:11:00.000000Z", "stale": true}}
        """))
        let state = try await Fixtures.api(transport).pullRequest(for: "01k5ws")
        #expect(!state.hasPullRequest)
        #expect(state.headBranch == "freek/cloud")
        #expect(state.stale)
        #expect(state.number == nil)
    }

    @Test func readsTheChecksAndTellsNoneApartFromUnreadable() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/cloud-workspaces/01k5ws/checks", .json("""
        {"data": {"head_sha": "0123456", "summary": {"state": "failure", "total": 2, "succeeded": 1, "failed": 1, "pending": 0, "skipped": 0},
          "checks": [{"id": "1", "name": "tests", "status": "completed", "conclusion": "failure",
            "details_url": "https://github.com/spatie/bloom/runs/1", "started_at": "2026-09-18T00:00:00Z",
            "completed_at": "2026-09-18T00:05:00Z", "summary": "2 tests failed"}],
          "fetched_at": "2026-09-18T00:11:00.000000Z", "stale": false}}
        """))
        let checks = try await Fixtures.api(transport).checks(for: "01k5ws")
        #expect(!checks.isEmpty)
        #expect(checks.summary.succeeded == 1)
        #expect(checks.checks.first?.conclusion == "failure")
        #expect(checks.checks.first?.completedAt != nil)

        let empty = FakeTransport()
        empty.on("GET", "/cloud-workspaces/01k5ws/checks", .json("""
        {"data": {"head_sha": "0123456", "summary": {"state": "none", "total": 0, "succeeded": 0, "failed": 0, "pending": 0, "skipped": 0},
          "checks": [], "fetched_at": "2026-09-18T00:11:00.000000Z", "stale": false}}
        """))
        #expect(try await Fixtures.api(empty).checks(for: "01k5ws").isEmpty)
    }

    @Test func mergingSendsTheMethodAndTheHeadCommit() async throws {
        let transport = FakeTransport()
        transport.on("POST", "/cloud-workspaces/01k5ws/pull-request/merge", .json("""
        {"data": {"has_pull_request": true, "number": 298, "state": "merged", "head_branch": "freek/cloud",
          "base_branch": "main", "stale": false}}
        """))
        let state = try await Fixtures.api(transport).mergePullRequest(
            "01k5ws", request: CloudMergeRequest(method: "squash", headSHA: "0123456")
        )
        #expect(state.state == "merged")
        let request = try #require(transport.requests.first)
        let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(body.contains("\"method\":\"squash\""))
        #expect(body.contains("\"head_sha\":\"0123456\""))
    }

    @Test func aRefusalToMergeKeepsRunbloomsOwnSentence() async throws {
        let transport = FakeTransport()
        transport.on("POST", "/cloud-workspaces/01k5ws/pull-request/merge", .json("""
        {"code": "not_mergeable", "message": "GitHub will not merge this yet. A review is required.", "merge_blockers": ["Waiting for a review."]}
        """, status: 409))
        await #expect(throws: RunbloomRefusal.self) {
            _ = try await Fixtures.api(transport).mergePullRequest("01k5ws", request: CloudMergeRequest(method: "merge"))
        }
    }

    /// A branch is prefixed with the GitHub login, the same prefix a local workspace cuts, and
    /// never with the display name, which can be edited into something that is not a valid ref.
    @Test func aBranchIsPrefixedWithTheGitHubLoginAndNeverTheDisplayName() {
        let connected = RunbloomAccount(id: "u", name: "Freek Van der Herten", email: "f@s.be", githubConnected: true, githubLogin: "FreekMurze")
        #expect(connected.branchPrefix == "freekmurze")
        #expect(CloudBranchName.suggestion(for: "queue retries", prefix: connected.branchPrefix) == "freekmurze/queue-retries")

        // No login is no prefix, not a guess from the name.
        let unknown = RunbloomAccount(id: "u", name: "Freek Van der Herten", email: "f@s.be", githubConnected: true)
        #expect(unknown.branchPrefix == nil)
        #expect(CloudBranchName.suggestion(for: "queue retries", prefix: unknown.branchPrefix) == "queue-retries")

        // A login from an account whose GitHub is no longer connected is not used either.
        let disconnected = RunbloomAccount(id: "u", name: "Freek", email: "f@s.be", githubConnected: false, githubLogin: "freekmurze")
        #expect(disconnected.branchPrefix == nil)
    }

}
