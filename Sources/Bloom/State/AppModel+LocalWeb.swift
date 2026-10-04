import Foundation
import BloomCore

/// Browser access to this running Bloom instance. The listener owns no runner or database; every
/// prompt uses the same transcript model as the Mac window, and all reads use its Store actor.
extension AppModel {
    func setLocalWebEnabled(_ enabled: Bool) {
        guard localWebEnabled != enabled else { return }
        localWebEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "localWeb.enabled")
        if enabled {
            startLocalWebIfEnabled()
        } else {
            localWebServer?.stop()
            localWebServer = nil
            localWebAddress = nil
            localWebToken = nil
            localWebError = nil
        }
    }

    func startLocalWebIfEnabled() {
        guard isLoaded, localWebEnabled, localWebServer == nil, store != nil else { return }
        localWebError = nil
        let token = BridgeRegistry.randomToken()
        do {
            let server = try LocalWebServer(
                handler: { [weak self] request in
                    guard let self else { return .text(503, "Bloom is closing") }
                    return await self.localWebResponse(to: request, token: token)
                },
                onReady: { [weak self] port in
                    Task { @MainActor [weak self] in
                        guard let self, self.localWebToken == token else { return }
                        self.localWebAddress = "http://127.0.0.1:\(port)"
                    }
                },
                onFailure: { [weak self] message in
                    Task { @MainActor [weak self] in
                        guard let self, self.localWebToken == token else { return }
                        self.localWebError = message
                        self.localWebAddress = nil
                    }
                }
            )
            localWebToken = token
            localWebServer = server
            server.start()
        } catch {
            localWebError = error.localizedDescription
        }
    }

    private func localWebResponse(to request: LocalWebServer.Request, token: String) async -> LocalWebServer.Response {
        guard localWebEnabled, localWebToken == token else { return .text(503, "Browser access is off") }
        if request.method == "GET", request.path == "/" {
            let nonce = BridgeRegistry.randomToken()
            return .init(
                contentType: "text/html; charset=utf-8",
                body: Data(LocalWebPage.html(nonce: nonce).utf8),
                contentSecurityPolicy: "default-src 'none'; script-src 'nonce-\(nonce)'; "
                    + "connect-src 'self'; style-src 'unsafe-inline'; img-src 'none'; "
                    + "base-uri 'none'; form-action 'self'"
            )
        }
        guard request.headers["authorization"] == "Bearer \(token)" else {
            return .text(401, "Enter the access code from Bloom Settings")
        }
        guard let store else { return .text(503, "Bloom is loading") }
        let parts = request.path.split(separator: "/").map(String.init)
        do {
            if request.method == "GET", parts == ["api", "workspaces"] {
                let workspaces = try await store.workspaces()
                let repos = Dictionary(uniqueKeysWithValues: try await store.repos().map { ($0.id, $0.name) })
                return json(workspaces.map { workspace in
                    WebWorkspace(
                        id: workspace.id, name: workspace.name,
                        project: repos[workspace.repoID] ?? "Project", branch: workspace.branch
                    )
                })
            }
            if request.method == "GET", parts.count == 4, parts[0] == "api",
               parts[1] == "workspaces", parts[3] == "chats" {
                let workspaceID = WorkspaceID(parts[2])
                guard let workspace = try await store.workspace(id: workspaceID), workspace.state == .active else {
                    return .text(404, "Workspace not found")
                }
                let sessions = try await store.sessions(workspaceID: workspaceID)
                return json(sessions.filter { $0.parentSessionID == nil }.map { session in
                    WebChat(
                        id: session.id, title: ChatListTool.title(of: session),
                        agent: session.agentKind.rawValue, state: session.state.rawValue
                    )
                })
            }
            if parts.count == 4, parts[0] == "api", parts[1] == "chats", parts[3] == "messages" {
                let sessionID = SessionID(parts[2])
                guard let session = try await store.session(id: sessionID),
                      session.archivedAt == nil, let workspaceID = session.workspaceID,
                      let workspace = try await store.workspace(id: workspaceID), workspace.state == .active else {
                    return .text(404, "Chat not found")
                }
                if request.method == "GET" {
                    let components = URLComponents(string: "http://localhost\(request.target)")
                    let after = components?.queryItems?.first(where: { $0.name == "after" })?.value.flatMap(Int.init)
                    let before = components?.queryItems?.first(where: { $0.name == "before" })?.value.flatMap(Int.init)
                    let fetched = if let before {
                        try await store.messages(sessionID: sessionID, beforeSeq: before, limit: 201)
                    } else if let after {
                        try await store.messages(sessionID: sessionID, afterSeq: after, limit: 200)
                    } else {
                        try await store.recentMessages(sessionID: sessionID, limit: 201)
                    }
                    let hasMoreEarlier = (before != nil || after == nil) && fetched.count > 200
                    let messages = hasMoreEarlier ? Array(fetched.dropFirst()) : fetched
                    let highest = messages.last?.seq ?? after ?? -1
                    let first = messages.first?.seq ?? before ?? -1
                    let streaming = existingModel(for: workspaceID)?.existingTranscript(for: sessionID)?.streamingText ?? ""
                    let decisions = try await store.permissionAskDecisions(sessionID: sessionID)
                    let worktree = workspace.path
                    // Provider decoding and Markdown highlighting can walk large rows. Keep that
                    // work off the main actor that also drives the Mac transcript.
                    let (rows, streamingHTML) = await Task.detached(priority: .utility) {
                        (
                            messages.compactMap { TranscriptClientRow.present($0, worktree: worktree) },
                            MarkdownHTML.render(streaming, imagesAsAltText: true).html
                        )
                    }.value
                    return json(WebMessages(
                        schemaVersion: 1, messages: rows, firstSeq: first, lastSeq: highest,
                        hasMoreEarlier: hasMoreEarlier, streaming: streaming,
                        streamingHTML: streamingHTML, decisions: decisions
                    ))
                }
                if request.method == "POST" {
                    guard request.headers["content-type"]?.hasPrefix("application/json") == true,
                          let prompt = try? JSONDecoder().decode(WebPrompt.self, from: request.body),
                          !prompt.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          prompt.text.count <= 32_000 else { return .text(400, "Enter a prompt up to 32,000 characters") }
                    let model = model(for: workspace)
                    if !model.hasReadSessions { await model.reloadSessions() }
                    guard let current = model.sessions.first(where: { $0.id == sessionID }) else {
                        return .text(404, "Chat not found")
                    }
                    let sent = await model.transcript(for: current).submit(prompt.text)
                    return sent ? json(WebAccepted(accepted: true)) : .text(503, "Bloom could not send this prompt")
                }
            }
            return .text(404, "Not found")
        } catch {
            return .text(500, "Bloom could not complete this request")
        }
    }

    private func json<T: Encodable>(_ value: T) -> LocalWebServer.Response {
        guard let data = try? JSONEncoder().encode(value) else { return .text(500, "Could not encode response") }
        return .init(body: data)
    }
}

private struct WebWorkspace: Encodable {
    let id: WorkspaceID
    let name: String
    let project: String
    let branch: String
}

private struct WebChat: Encodable {
    let id: SessionID
    let title: String
    let agent: String
    let state: String
}

private struct WebPrompt: Decodable {
    let text: String
}

private struct WebAccepted: Encodable {
    let accepted: Bool
}

private struct WebMessages: Encodable {
    let schemaVersion: Int
    let messages: [TranscriptClientRow]
    let firstSeq: Int
    let lastSeq: Int
    let hasMoreEarlier: Bool
    let streaming: String
    let streamingHTML: String
    let decisions: [String: String]
}
