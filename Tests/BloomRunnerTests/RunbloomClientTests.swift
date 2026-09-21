import AsyncHTTPClient
import BloomCore
import Foundation
import NIOCore
import Synchronization
import Testing
@testable import BloomRunner

struct RunbloomClientTests {
    private static func withFake(_ body: (FakeControlServer, RunbloomClient) async throws -> Void) async throws {
        let fake = try await FakeControlServer.start()
        let client = RunbloomClient(baseURL: fake.baseURL + "/", workspaceID: fake.workspaceID, secret: fake.secret, http: .shared)
        do {
            try await body(fake, client)
        } catch {
            await fake.stop()
            throw error
        }
        await fake.stop()
    }

    @Test func summaryAndUsageArePostedAsGivenWithTheSecret() async throws {
        try await Self.withFake { fake, client in
            let summary = Data(#"{"revision":42}"#.utf8)
            let usage = Data(#"{"machine_boot_id":"boot","sequence":1}"#.utf8)
            try await client.postSummary(summary)
            try await client.postUsage(usage)

            let posted = fake.requests
            #expect(posted.map(\.method) == ["POST", "POST"])
            #expect(posted.map(\.path) == ["/summary", "/usage"])
            #expect(posted.allSatisfy { $0.authorization == "Bearer secret-for-tests" })
            #expect(posted.allSatisfy { $0.contentType == "application/json" })
            #expect(posted.map(\.body) == [summary, usage])
            #expect(posted.allSatisfy { $0.proof["version"] == "1" })
            #expect(posted.allSatisfy { $0.proof["key-id"]?.count == 64 })
            #expect(Set(posted.compactMap { $0.proof["request-id"] }).count == 2)
            #expect(posted.allSatisfy { $0.proof["signature"]?.isEmpty == false })
        }
    }

    @Test func environmentIsRead() async throws {
        try await Self.withFake { fake, client in
            fake.environmentBody = #"{"version":1,"variables":{"APP_ENV":"local","EMPTY":""}}"#
            let environment = try await client.environment()
            #expect(environment.variables == ["APP_ENV": "local", "EMPTY": ""])
            let request = try #require(fake.requests.first)
            #expect(request.method == "GET")
            #expect(request.path == "/environment")
            #expect(request.body.isEmpty)
        }
    }

    @Test("setup secrets use exact issue and one-use consume requests")
    func setupSecretHandoff() async throws {
        try await Self.withFake { fake, client in
            let id = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
            fake.script("POST", "/secret-handoffs", .raw(201,
                #"{"version":1,"handoff_id":"01ARZ3NDEKTSV4RRFFQ69G5FAV","expires_at":"2099-01-01T00:00:00Z"}"#))
            fake.script("POST", "/secret-handoffs/\(id)/consume", .raw(200,
                #"{"version":1,"secrets":{"SETUP_TOKEN":"sentinel"}}"#))
            let attempt = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
            let secrets = try await client.secrets(for: .setup(attemptID: attempt))
            #expect(secrets == ["SETUP_TOKEN": "sentinel"])
            let issue = try #require(fake.requests("POST", "/secret-handoffs").first?.json)
            #expect(Set(issue.keys) == ["version", "kind", "attempt_id"])
            #expect(issue["version"] as? Int == 1)
            #expect(issue["kind"] as? String == "setup")
            #expect(issue["attempt_id"] as? String == attempt.uuidString.lowercased())
            let consume = try #require(fake.requests("POST", "/secret-handoffs/\(id)/consume").first?.json)
            #expect(Set(consume.keys) == ["version"])
        }
    }

    @Test("service handoff uses stable id and cancels an unconsumed handoff")
    func serviceSecretFailureCancels() async throws {
        try await Self.withFake { fake, client in
            let id = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
            fake.script("POST", "/secret-handoffs", .raw(201,
                #"{"version":1,"handoff_id":"01ARZ3NDEKTSV4RRFFQ69G5FAV","expires_at":"2099-01-01T00:00:00Z"}"#))
            fake.script("POST", "/secret-handoffs/\(id)/consume", .refusal(
                status: 409, code: "secret_handoff_unavailable", message: "That secret handoff is no longer available."))
            fake.script("DELETE", "/secret-handoffs/\(id)", .noContent)
            let launch = try #require(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
            await #expect(throws: (any Error).self) {
                _ = try await client.secrets(for: .service(id: "web", launchID: launch))
            }
            let issue = try #require(fake.requests("POST", "/secret-handoffs").first?.json)
            #expect(Set(issue.keys) == ["version", "kind", "service_id", "launch_id"])
            #expect(issue["service_id"] as? String == "web")
            #expect(fake.requests("DELETE", "/secret-handoffs/\(id)").count == 1)
        }
    }

    @Test("service manifest uses stable ids and mutable display names")
    func serviceManifest() async throws {
        try await Self.withFake { fake, client in
            fake.script("PUT", "/service-manifest", .noContent)
            try await client.syncServiceManifest([.init(id: "web", name: "Web display", command: "serve")])
            let json = try #require(fake.requests("PUT", "/service-manifest").first?.json)
            #expect(json["version"] as? Int == 1)
            let services = try #require(json["services"] as? [[String: String]])
            #expect(services == [["id": "web", "name": "Web display"]])
        }
    }

    @Test func legacyBroadEnvironmentIsRefused() async throws {
        try await Self.withFake { fake, client in
            fake.environmentBody = #"{"environment":{"TOKEN":"must-not-be-broad"}}"#
            await #expect(throws: RunbloomError.unexpected(status: 200)) {
                _ = try await client.environment()
            }
        }
    }

    /// The body runbloom.app actually answers with, written out rather than re-encoded, because
    /// what is being tested is that the two sides agree about the shape.
    @Test func membersAreReadWithTheirHandles() async throws {
        try await Self.withFake { fake, client in
            fake.membersBody = """
            {"members": [
              {"user_id": "01k5bx7j9d3v2r8q6m4n0p1s2t", "name": "Freek Van der Herten", "handle": "freek"},
              {"user_id": "01k5bx7j9d3v2r8q6m4n0p1s2u", "name": "Sebastian De Deyne", "handle": "sebdd"}
            ]}
            """
            let members = try await client.members()

            #expect(members.map(\.handle) == ["freek", "sebdd"])
            #expect(members.first?.userID == "01k5bx7j9d3v2r8q6m4n0p1s2t")
            #expect(members.first?.name == "Freek Van der Herten")
            let request = try #require(fake.requests.first)
            #expect(request.method == "GET")
            #expect(request.path == "/members")
        }
    }

    /// A team with nobody in it yet, and a machine that has never asked, must not look the same.
    @Test func anEmptyMemberListIsStillAnAnswer() async throws {
        try await Self.withFake { fake, client in
            fake.membersBody = #"{"members": []}"#
            let members = try await client.members()
            #expect(members.isEmpty)
        }
    }

    @Test func aTurnIsRegisteredWithTheTokenChatAndAgent() async throws {
        try await Self.withFake { fake, client in
            let turn = try await client.registerTurn(
                kind: .turn, chatID: "chat-1", agent: .claudeCode,
                model: "claude-sonnet-4-5", sessionToken: "jwt.for.prompter"
            )
            #expect(turn == FakeControlServer.turnID(1))

            let json = try #require(fake.requests("POST", "/turns").first?.json)
            #expect(json["kind"] as? String == "turn")
            #expect(json["session_token"] as? String == "jwt.for.prompter")
            #expect(json["chat_id"] as? String == "chat-1")
            #expect(json["agent"] as? String == "claude")
            #expect(json["model"] as? String == "claude-sonnet-4-5")
        }
    }

    @Test func aTerminalIsRegisteredWithNullChatAndAgent() async throws {
        try await Self.withFake { fake, client in
            _ = try await client.registerTurn(
                kind: .terminal, chatID: nil, agent: nil, model: nil, sessionToken: "jwt"
            )
            let json = try #require(fake.requests("POST", "/turns").first?.json)
            #expect(json["kind"] as? String == "terminal")
            #expect(json["chat_id"] is NSNull)
            #expect(json["agent"] is NSNull)
            #expect(json["model"] is NSNull)
        }
    }

    @Test func startingDecodesOpaqueGrantsByAgentAndSkipsAgentsItDoesNotKnow() async throws {
        try await Self.withFake { fake, client in
            fake.setStart(turnID: "01jturnstart", response: .grant(
                models: [
                    "claude": "claude-sonnet-4-5",
                    "codex": "gpt-5-codex",
                    "someday": "future-model",
                ],
                environment: ["GREETING": "hello"]
            ))
            let start = try await client.startTurn("01jturnstart")

            #expect(start.modelGrants[.claudeCode]?.model == "claude-sonnet-4-5")
            #expect(start.modelGrants[.codex]?.operation == .openAIResponsesStream)
            #expect(start.modelGrants.count == 2)
            #expect(start.environment == ["GREETING": "hello"])
            #expect(!start.description.contains(String(repeating: "a", count: 64)))

            let request = try #require(fake.requests.first)
            #expect(request.method == "POST")
            #expect(request.path == "/turns/01jturnstart/start")
            #expect(request.body.isEmpty)
        }
    }

    @Test func endingIsADelete() async throws {
        try await Self.withFake { fake, client in
            try await client.endTurn("01jturnend")
            #expect(fake.requests.map(\.method) == ["DELETE"])
            #expect(fake.requests.map(\.path) == ["/turns/01jturnend"])
        }
    }

    @Test("terminal grant issue, renewal and cancellation use the exact versioned bodies")
    func opaqueModelGrantCalls() async throws {
        try await Self.withFake { fake, client in
            let issueID = UUID(uuidString: "e579cbaa-3143-4e2d-8503-9cf620433742")!
            let renewID = UUID(uuidString: "bc2ba416-995c-4cd7-b3d6-b13a7b59f3cb")!
            let streamID = UUID(uuidString: "19c558bd-8783-4059-85e0-878d48ec19c8")!
            let old = String(repeating: "o", count: 64)
            let rotated = String(repeating: "r", count: 64)
            fake.script("POST", "/turns/terminal-1/model-grants", .modelGrant(status: 201))
            fake.script("POST", "/turns/terminal-1/model-grant-renewals", .modelGrant(
                status: 200, token: rotated, revision: 2
            ))
            fake.script(
                "DELETE", "/model-gateway/requests/\(streamID.uuidString.lowercased())", .noContent
            )

            _ = try await client.issueModelGrant(
                turnID: "terminal-1", agent: .codex, model: "gpt-5-codex", requestID: issueID
            )
            _ = try await client.renewModelGrant(
                turnID: "terminal-1", grant: old, requestID: renewID
            )
            try await client.cancelModelStream(requestID: streamID, grant: rotated)

            let issue = try #require(fake.requests("POST", "/turns/terminal-1/model-grants").first?.json)
            #expect(Set(issue.keys) == ["version", "agent", "model", "request_id"])
            #expect(issue["request_id"] as? String == issueID.uuidString.lowercased())
            let renewal = try #require(fake.requests(
                "POST", "/turns/terminal-1/model-grant-renewals"
            ).first?.json)
            #expect(Set(renewal.keys) == ["version", "grant", "request_id"])
            #expect(renewal["grant"] as? String == old)
            let cancellation = try #require(fake.requests(
                "DELETE", "/model-gateway/requests/\(streamID.uuidString.lowercased())"
            ).first?.json)
            #expect(Set(cancellation.keys) == ["version", "grant"])
            #expect(cancellation["grant"] as? String == rotated)
        }
    }

    @Test("the fake server pins bootstrap grant rotation and bodies")
    func personBoundGithubCredentialProtocol() async throws {
        try await Self.withFake { fake, client in
            let first = String(repeating: "a", count: 64)
            let third = String(repeating: "c", count: 64)
            fake.script("POST", "/github-credential-grants/bootstrap", .raw(201, """
            {"grant":{"token":"\(first)","expires_at":"2026-09-20T12:00:00Z","revision":1}}
            """))
            fake.script("POST", "/github-credentials", .raw(200, """
            {"credential":{"username":"x-access-token","token":"raw-operation-token","expires_at":"2026-09-20T12:02:00Z"},"next_grant":{"token":"\(third)","expires_at":"2026-09-20T12:03:00Z","revision":3}}
            """))

            let bootstrap = try await client.bootstrapGithubCredentialGrant()
            let requestID = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
            let issued = try await client.githubCredentials(
                grant: bootstrap.token, operation: .gitRead, requestID: requestID
            )

            #expect(bootstrap.token == first)
            #expect(issued.token == "raw-operation-token")
            #expect(issued.nextGrant.token == third)
            let bootstrapRequest = try #require(fake.requests("POST", "/github-credential-grants/bootstrap").first)
            #expect(bootstrapRequest.body.isEmpty)
            let exchange = try #require(fake.requests("POST", "/github-credentials").first?.json)
            #expect(Set(exchange.keys) == ["grant", "operation", "request_id"])
            #expect(exchange["grant"] as? String == first)
            #expect(exchange["operation"] as? String == "git_read")
            #expect(exchange["request_id"] as? String == requestID.uuidString.lowercased())
            #expect(exchange["repository"] == nil)
            #expect(exchange["turn_id"] == nil)
            #expect(exchange["chat_id"] == nil)
        }
    }

    @Test("a rotating v2 grant is never replayed after an authentication refusal")
    func personBoundGrantIsNotRetried() async throws {
        let fake = try await FakeControlServer.start()
        let file = Mutex(fake.secret)
        let secret = WorkspaceSecret("stale-machine-secret") { file.withLock { $0 } }
        let client = RunbloomClient(baseURL: fake.baseURL, workspaceID: fake.workspaceID, secret: secret, http: .shared)
        do {
            _ = try await client.githubCredentials(
                grant: String(repeating: "g", count: 64), operation: .gitRead, requestID: UUID()
            )
            Issue.record("A stale machine secret exchanged a grant.")
        } catch {
            #expect(error is RunbloomError)
        }
        let requests = fake.requests("POST", "/github-credentials")
        #expect(requests.count == 1)
        #expect(requests.first?.authorization == "Bearer stale-machine-secret")
        #expect(secret.current == "stale-machine-secret")
        await fake.stop()
    }

    @Test("a started turn decodes an opaque v2 grant without exposing it in descriptions")
    func startedTurnCarriesPersonBoundGrant() async throws {
        try await Self.withFake { fake, client in
            let token = String(repeating: "g", count: 64)
            fake.setStart(turnID: "01jv2turn", response: .grant(
                githubGrant: (token, "2026-09-20T12:00:00Z", 9)
            ))
            let started = try await client.startTurn("01jv2turn")
            #expect(started.githubCredentialGrant?.token == token)
            #expect(started.githubCredentialGrant?.revision == 9)
            #expect(!String(reflecting: started).contains(token))
            #expect(!started.description.contains(token))
        }
    }

    @Test func aProjectIconAndAnExplicitMissUseTheAuthenticatedMachineEndpoint() async throws {
        try await Self.withFake { fake, client in
            let icon = Data("canonical-png".utf8)
            try await client.reportProjectIcon(ProjectIconReport(
                requestedRevision: 4,
                detectorVersion: 2,
                sourceCommit: String(repeating: "a", count: 40),
                icon: icon
            ))
            try await client.reportProjectIcon(ProjectIconReport(
                requestedRevision: 5,
                detectorVersion: 2,
                sourceCommit: String(repeating: "b", count: 40),
                icon: nil
            ))

            let requests = fake.requests("PUT", "/project-icon")
            #expect(requests.count == 2)
            #expect(requests.allSatisfy { $0.authorization == "Bearer secret-for-tests" })
            #expect(requests.allSatisfy { $0.contentType == "application/json" })
            let first = try #require(requests.first?.json)
            #expect(first["requested_revision"] as? Int == 4)
            #expect(first["detector_version"] as? Int == 2)
            #expect(first["source_commit"] as? String == String(repeating: "a", count: 40))
            let sentIcon = try #require(first["icon"] as? [String: Any])
            #expect(sentIcon["data"] as? String == icon.base64EncodedString())
            #expect(sentIcon["sha256"] as? String == "d33a5e3a7ed7cc0d9db661342609a33db44f10cdab3cc1cd5c3ed833b52c3d22")
            #expect(requests.last?.json?["icon"] is NSNull)
        }
    }

    @Test func theProjectIconRequestComesOnlyFromTheAuthenticatedMachineEndpoint() async throws {
        try await Self.withFake { fake, client in
            fake.script("GET", "/project-icon-request", .json(200, [
                "project_icon": [
                    "requested_revision": 2,
                    "detector_version": 1,
                    "repository_default_branch": "main",
                    "should_discover": true,
                ],
                "poll_after_seconds": 300,
            ]))

            let answer = try await client.projectIconRequest()

            #expect(answer.projectIcon?.identityRequest == ProjectIconDiscoveryRequest(
                requestedRevision: 2,
                detectorVersion: 1,
                repositoryDefaultBranch: "main"
            ))
            #expect(answer.projectIcon?.shouldDiscover == true)
            #expect(answer.pollAfter == .seconds(300))
            let requests = fake.requests("GET", "/project-icon-request")
            #expect(requests.count == 1)
            let sent = try #require(requests.first)
            #expect(sent.authorization == "Bearer secret-for-tests")
            #expect(sent.body.isEmpty)
            #expect(sent.contentType == nil)
        }
    }

    @Test func resolvedAndMissingProjectIconRequestsDoNotInventDiscoveryWork() async throws {
        try await Self.withFake { fake, client in
            fake.script("GET", "/project-icon-request",
                        .json(200, [
                            "project_icon": [
                                "requested_revision": 3,
                                "detector_version": 1,
                                "repository_default_branch": "main",
                                "should_discover": false,
                            ],
                            "poll_after_seconds": 300,
                        ]),
                        .json(200, ["project_icon": NSNull(), "poll_after_seconds": 300]))

            let resolved = try await client.projectIconRequest()
            let missing = try await client.projectIconRequest()

            #expect(resolved.projectIcon?.identityRequest?.requestedRevision == 3)
            #expect(resolved.projectIcon?.discoveryRequest == nil)
            #expect(missing.projectIcon == nil)
        }
    }

    @Test func projectIconRequestUnavailableHonoursTheBoundedRetryAfter() async throws {
        try await Self.withFake { fake, client in
            fake.script("GET", "/project-icon-request", .init(
                status: 503,
                body: #"{"code":"project_icon_request_unavailable","message":"Try again."}"#,
                headers: ["Retry-After": "60"]
            ))

            await #expect(throws: ProjectIconRequestUnavailable(retryAfter: .seconds(60))) {
                try await client.projectIconRequest()
            }
        }
    }

    @Test func projectIconRequestPreservesFeatureAndReplacementRefusals() async throws {
        try await Self.withFake { fake, client in
            let refusals: [(Int, String)] = [(403, "github_disabled"), (404, "not_found"), (401, "invalid_workspace_secret")]
            for (status, code) in refusals {
                fake.script("GET", "/project-icon-request", .refusal(status: status, code: code, message: "Refused."))
                do {
                    _ = try await client.projectIconRequest()
                    Issue.record("A refused request was accepted.")
                } catch let error as RunbloomError {
                    #expect(error == .refused(status: status, code: code, message: "Refused.", limit: nil, retryAfter: nil))
                } catch {
                    Issue.record("The refusal changed type: \(error)")
                }
            }
        }
    }

    /// runbloom.app decides; the machine passes the turn and the key, and hands the agent whatever
    /// runbloom.app said, word for word, because that sentence is the only place the team switch
    /// is named.
    @Test func aCloudWorkspaceIsAskedForWithTheTurnAndTheKey() async throws {
        try await Self.withFake { fake, client in
            fake.script("POST", "/cloud-workspaces", .json(201, ["workspace": [
                "id": "01k5new", "name": "Try the retry", "state": "setting_up", "url": "https://runbloom.app/w/01k5new",
            ]]))
            let request = CloudWorkspaceRequest(order: CloudWorkspaceOrder(name: "Try the retry", baseBranch: "main", runSetup: false),
                                                turnID: "01jturn", idempotencyKey: "key-1")
            let answer = await client.createCloudWorkspace(request)
            #expect(answer == .created(CloudWorkspaceCreated(id: "01k5new", name: "Try the retry", state: "setting_up",
                                                             url: "https://runbloom.app/w/01k5new")))
            let sent = try #require(fake.requests("POST", "/cloud-workspaces").first)
            #expect(sent.idempotencyKey == "key-1")
            #expect(sent.json?["turn_id"] as? String == "01jturn")
            #expect(sent.json?["name"] as? String == "Try the retry")
            #expect(sent.json?["base_branch"] as? String == "main")
            #expect(sent.json?["run_setup"] as? Bool == false)
            #expect(sent.json?["branch"] == nil, "absent rather than null, so runbloom.app derives it")
            #expect(sent.json?["prompt"] == nil, "no prompt until the handoff exists")

            let off = "Creating Bloom Cloud workspaces from an agent is off for this team. An admin can turn it on in Team settings."
            fake.script("POST", "/cloud-workspaces", .refusal(code: "agent_creation_disabled", message: off))
            #expect(await client.createCloudWorkspace(request) == .refused(off))

            fake.script("POST", "/cloud-workspaces", FakeControlServer.Scripted(status: 503, body: "down"))
            guard case .refused(let unreachable) = await client.createCloudWorkspace(request) else {
                Issue.record("An unreachable runbloom.app made something up"); return
            }
            #expect(unreachable.contains("no Bloom Cloud workspace was created"))
        }
    }

    /// With a prompt, the creating chat's agent and model travel as `controls`, which runbloom.app
    /// requires so the opening turn is registered with the agent whose key it hands out.
    @Test func aPromptTravelsWithTheCreatingChatsControls() async throws {
        try await Self.withFake { fake, client in
            fake.script("POST", "/cloud-workspaces", .json(201, ["workspace": [
                "id": "01k5new", "name": "Spike", "state": "setting_up", "url": "https://runbloom.app/w/01k5new",
            ]]))
            let request = CloudWorkspaceRequest(
                order: CloudWorkspaceOrder(name: "Spike", prompt: "Try the retry queue", effort: "medium"),
                turnID: "01jturn",
                idempotencyKey: "key-1",
                agent: "codex",
                model: "gpt-5.6-sol",
                effort: "medium"
            )
            _ = await client.createCloudWorkspace(request)
            let sent = try #require(fake.requests("POST", "/cloud-workspaces").first?.json)
            #expect(sent["prompt"] as? String == "Try the retry queue")
            let controls = try #require(sent["controls"] as? [String: Any])
            #expect(controls["agent"] as? String == "codex")
            #expect(controls["model"] as? String == "gpt-5.6-sol")
            #expect(controls["effort"] as? String == "medium")
        }
    }

    @Test func anOpeningIsFetchedAndNoneIsNil() async throws {
        try await Self.withFake { fake, client in
            fake.script("GET", "/opening", .json(200, ["opening": [
                "turn_id": "01jopen", "prompt": "Try the retry queue", "controls": ["agent": "codex"],
                "prompted_by": ["user_id": "01k5freek", "name": "Freek", "handle": "freek"], "expires_at": "2026-09-19T12:00:00Z",
            ]]))
            let opening = try #require(try await client.opening())
            #expect(opening.turnID == "01jopen")
            #expect(opening.prompt == "Try the retry queue")
            #expect(opening.controls["agent"] == .string("codex"))
            #expect(opening.promptedBy.userID == "01k5freek")

            fake.script("GET", "/opening", .refusal(status: 404, code: "not_found", message: "No opening."))
            #expect(try await client.opening() == nil, "a workspace a person made has none")

            fake.script("DELETE", "/opening", .noContent)
            try await client.acknowledgeOpening()
            #expect(fake.requests("DELETE", "/opening").count == 1)
        }
    }

    @Test func expiryReadsWithAndWithoutAFraction() throws {
        let whole = try #require(PersonBoundGithubGrantBody.date("2026-09-17T10:00:00Z"))
        let micro = try #require(PersonBoundGithubGrantBody.date("2026-09-17T10:00:00.500000Z"))
        #expect(micro.timeIntervalSince(whole) == 0.5)
        #expect(PersonBoundGithubGrantBody.date("tomorrow") == nil)
    }

    @Test func aLimitRefusalCarriesTheLimitAndRetryAfter() async throws {
        try await Self.withFake { fake, client in
            fake.setStart(turnID: "t1", response: .limit("concurrent_machines", message: "Wait for another.", retryAfter: 60))
            await #expect(throws: RunbloomError.refused(status: 429, code: "limit_reached", message: "Wait for another.", limit: "concurrent_machines", retryAfter: 60)) {
                try await client.startTurn("t1")
            }
        }
    }

    @Test func refusalsAreMappedForEveryEndpoint() async throws {
        try await Self.withFake { fake, client in
            fake.script("POST", "/turns", .refusal(code: "missing_ability", message: "No prompting."))
            await #expect(throws: RunbloomError.refused(status: 403, code: "missing_ability", message: "No prompting.", limit: nil, retryAfter: nil)) {
                try await client.registerTurn(
                    kind: .turn, chatID: "c", agent: .codex, model: "gpt-5-codex",
                    sessionToken: "jwt"
                )
            }
            fake.setStart(turnID: "t2", response: .refusal(status: 409, code: "turn_not_startable", message: "Too old."))
            await #expect(throws: RunbloomError.refused(status: 409, code: "turn_not_startable", message: "Too old.", limit: nil, retryAfter: nil)) {
                try await client.startTurn("t2")
            }
            fake.script("POST", "/github-credentials", .refusal(code: "credential_grant_invalid", message: "Invalid grant."))
            await #expect(throws: RunbloomError.refused(status: 403, code: "credential_grant_invalid", message: "Invalid grant.", limit: nil, retryAfter: nil)) {
                try await client.githubCredentials(
                    grant: String(repeating: "g", count: 64), operation: .gitWrite,
                    requestID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
                )
            }
        }
    }

    @Test func aServerErrorIsUnreachableAndABodilessRefusalIsUnexpected() async throws {
        try await Self.withFake { fake, client in
            fake.script("POST", "/summary", FakeControlServer.Scripted(status: 503, body: "down"))
            await #expect(throws: RunbloomError.unreachable("runbloom.app answered 503.")) {
                try await client.postSummary(Data("{}".utf8))
            }
            fake.script("POST", "/usage", FakeControlServer.Scripted(status: 422, body: "<html>"))
            await #expect(throws: RunbloomError.unexpected(status: 422)) {
                try await client.postUsage(Data("{}".utf8))
            }
        }
    }

    @Test func aWrongSecretIsRefusedAndNeverRepeatedInTheError() async throws {
        let fake = try await FakeControlServer.start()
        let secret = "the-wrong-secret-value"
        let client = RunbloomClient(baseURL: fake.baseURL, workspaceID: fake.workspaceID, secret: secret, http: .shared)
        do {
            try await client.postSummary(Data("{}".utf8))
            Issue.record("A wrong secret was accepted.")
        } catch {
            #expect(error as? RunbloomError == .refused(status: 401, code: "invalid_workspace_secret", message: "The workspace secret is not valid.", limit: nil, retryAfter: nil))
            #expect(fake.requests.count == 1, "The file held no other secret, so the call is not sent again")
            #expect(!String(describing: error).contains(secret))
            #expect(!error.localizedDescription.contains(secret))
        }
        await fake.stop()
    }

    @Test func aRefusedSecretIsReadAgainAndTheCallSentOnceMoreWithTheRotatedOne() async throws {
        let fake = try await FakeControlServer.start()
        let file = Mutex("the-secret-before-rotation")
        let secret = WorkspaceSecret(file.withLock { $0 }) { file.withLock { $0 } }
        let client = RunbloomClient(baseURL: fake.baseURL, workspaceID: fake.workspaceID, secret: secret, http: .shared)
        file.withLock { $0 = fake.secret }
        try await client.postSummary(Data("{}".utf8))
        #expect(fake.requests.map(\.authorization) == ["Bearer the-secret-before-rotation", "Bearer \(fake.secret)"])
        #expect(Set(fake.requests.compactMap { $0.proof["request-id"] }).count == 2,
                "a transport retry must sign a fresh proof")
        #expect(Set(fake.requests.compactMap { $0.proof["signature"] }).count == 2)
        #expect(secret.current == fake.secret)
        await fake.stop()
    }

    @Test func aRotatedSecretIsTakenFromTheFileAndAnUnreadableFileKeepsTheOldOne() {
        let file = Mutex<String?>("second")
        let secret = WorkspaceSecret("first") {
            guard let value = file.withLock({ $0 }) else { throw CocoaError(.fileReadCorruptFile) }
            return value
        }
        #expect(secret.reload())
        #expect(secret.current == "second")
        #expect(!secret.reload(), "The same secret again is no change")
        file.withLock { $0 = nil }
        #expect(!secret.reload())
        #expect(secret.current == "second")
    }

    @Test func anUnreachableHostNeverRepeatsTheSecret() async throws {
        let fake = try await FakeControlServer.start()
        let address = fake.baseURL
        await fake.stop()
        let secret = "secret-that-must-not-leak"
        let client = RunbloomClient(baseURL: address, workspaceID: "01jgone", secret: secret, http: .shared, timeout: .milliseconds(500))
        do {
            _ = try await client.environment()
            Issue.record("A stopped server answered.")
        } catch {
            guard case .unreachable = error as? RunbloomError else {
                Issue.record("Expected unreachable, got \(error)")
                return
            }
            #expect(!String(describing: error).contains(secret))
            #expect(!error.localizedDescription.contains(secret))
        }
    }

    @Test func theKeySetIsServedWhenSet() async throws {
        try await Self.withFake { fake, _ in
            var request = HTTPClientRequest(url: fake.baseURL + "/.well-known/jwks.json")
            request.method = .GET
            let missing = try await HTTPClient.shared.execute(request, timeout: .seconds(5))
            #expect(missing.status.code == 404)

            fake.jwks = Data(#"{"keys":[]}"#.utf8)
            let found = try await HTTPClient.shared.execute(request, timeout: .seconds(5))
            #expect(found.status.code == 200)
            let body = try await found.body.collect(upTo: 1024)
            #expect(String(buffer: body) == #"{"keys":[]}"#)
        }
    }
}
