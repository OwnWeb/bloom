import Foundation

/// A separate CLI configuration home. The CLI owns the credentials inside it.
public struct AgentAccountProfile: Codable, Hashable, Identifiable, Sendable {
    public let id: AgentAccountProfileID
    public let kind: AgentKind
    public var name: String

    public init(id: AgentAccountProfileID = .new(), kind: AgentKind, name: String) {
        self.id = id
        self.kind = kind
        self.name = name
    }
}

public enum AgentAccountEnvironment {
    public static func shellArguments(kind: AgentKind, home: String?) -> [String] {
        guard let home else { return [] }
        switch kind {
        case .claudeCode:
            return [
                "-u", "ANTHROPIC_API_KEY", "-u", "CLAUDE_CODE_OAUTH_TOKEN",
                "CLAUDE_CONFIG_DIR=\(home)"
            ]
        case .codex: return ["-u", "OPENAI_API_KEY", "-u", "CODEX_API_KEY", "CODEX_HOME=\(home)"]
        case .grok: return ["-u", "XAI_API_KEY", "GROK_HOME=\(home)"]
        case .cursor, .openCode: return []
        }
    }

    public static func applying(
        kind: AgentKind, home: String?, to environment: [String: String]
    ) -> [String: String] {
        guard let home else { return environment }
        var result = environment
        switch kind {
        case .claudeCode:
            result.removeValue(forKey: "ANTHROPIC_API_KEY")
            result.removeValue(forKey: "CLAUDE_CODE_OAUTH_TOKEN")
            result["CLAUDE_CONFIG_DIR"] = home
        case .codex:
            result.removeValue(forKey: "OPENAI_API_KEY")
            result.removeValue(forKey: "CODEX_API_KEY")
            result["CODEX_HOME"] = home
        case .grok:
            result.removeValue(forKey: "XAI_API_KEY")
            result["GROK_HOME"] = home
        case .cursor, .openCode:
            break
        }
        return result
    }
}

extension Store {
    private static var agentProfilesKey: String { "agent.accounts.profiles" }

    public func agentAccountProfiles() throws -> [AgentAccountProfile] {
        guard let raw = try setting(Self.agentProfilesKey), let data = raw.data(using: .utf8) else { return [] }
        return try JSONDecoder().decode([AgentAccountProfile].self, from: data)
    }

    public func createAgentAccountProfile(kind: AgentKind, name: String) throws -> AgentAccountProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, kind.canRunWorkspaces else {
            throw AgentAccountProfileError.invalidNameOrProvider
        }
        var profiles = try agentAccountProfiles()
        guard !profiles.contains(where: {
            $0.kind == kind && $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }) else { throw AgentAccountProfileError.duplicateName }
        let profile = AgentAccountProfile(kind: kind, name: trimmed)
        let home = agentAccountHome(profile)
        try FileManager.default.createDirectory(
            atPath: home, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        profiles.append(profile)
        let data = try JSONEncoder().encode(profiles)
        try setSetting(Self.agentProfilesKey, String(decoding: data, as: UTF8.self))
        return profile
    }

    /// A profile with saved conversations still owns their CLI thread. Refuse removal rather than
    /// making the next turn silently switch accounts or lose its server-side context.
    public func removeAgentAccountProfile(id: AgentAccountProfileID) throws {
        guard let uuid = UUID(uuidString: id.rawValue),
              uuid.uuidString.lowercased() == id.rawValue else {
            throw AgentAccountProfileError.invalidIdentifier
        }
        let profiles = try agentAccountProfiles()
        guard let profile = profiles.first(where: { $0.id == id }) else {
            throw AgentAccountProfileError.unknownProfile
        }
        let bound = try db.query(
            """
            SELECT COUNT(*) AS n FROM settings preference
            JOIN sessions chat ON preference.key = 'agent.session.' || chat.id || '.account'
            WHERE preference.value = ?
            """, [.text(id.rawValue)]
        ).first?.int("n") ?? 0
        guard bound == 0 else { throw AgentAccountProfileError.inUse(Int(bound)) }

        let home = URL(fileURLWithPath: agentAccountHome(profile))
        let staged = home.deletingLastPathComponent()
            .appendingPathComponent("\(id.rawValue).removing-\(UUID().uuidString.lowercased())")
        let hasHome = FileManager.default.fileExists(atPath: home.path)
        if hasHome { try FileManager.default.moveItem(at: home, to: staged) }

        do {
            let remaining = profiles.filter { $0.id != id }
            let encoded = try JSONEncoder().encode(remaining)
            try db.transaction {
                try setSetting(
                    Self.agentProfilesKey,
                    remaining.isEmpty ? nil : String(decoding: encoded, as: UTF8.self)
                )
                try db.run(
                    "DELETE FROM settings WHERE key LIKE 'agent.project.%' AND value = ?",
                    [.text(id.rawValue)]
                )
                try db.run(
                    "DELETE FROM settings WHERE key LIKE 'agent.session.%.account' AND value = ?",
                    [.text(id.rawValue)]
                )
            }
        } catch {
            if hasHome { try? FileManager.default.moveItem(at: staged, to: home) }
            throw error
        }

        if hasHome {
            do {
                try FileManager.default.removeItem(at: staged)
            } catch {
                throw AgentAccountProfileError.cleanupFailed(staged.path)
            }
        }
    }

    public nonisolated func agentAccountHome(_ profile: AgentAccountProfile) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent()
            .appendingPathComponent("Agent Accounts", isDirectory: true)
            .appendingPathComponent(profile.kind.rawValue, isDirectory: true)
            .appendingPathComponent(profile.id.rawValue, isDirectory: true).path
    }

    public func defaultAgent(for repoID: RepoID) throws -> AgentKind? {
        try setting("agent.project.\(repoID.rawValue).default").flatMap(AgentKind.init(rawValue:))
    }

    public func projectAgentDefaults(for repoID: RepoID) throws -> (model: String, effort: String, kind: AgentKind)? {
        guard let kind = try defaultAgent(for: repoID),
              let model = try setting("agent.project.\(repoID.rawValue).model") else { return nil }
        return (model, try setting("agent.project.\(repoID.rawValue).effort") ?? "high", kind)
    }

    public func setProjectAgentDefaults(
        for repoID: RepoID, model: String?, effort: String?, kind: AgentKind?
    ) throws {
        guard model == nil || (kind?.canRunWorkspaces == true && !(model ?? "").isEmpty) else {
            throw AgentAccountProfileError.invalidNameOrProvider
        }
        try db.transaction {
            let prefix = "agent.project.\(repoID.rawValue)"
            try setSetting("\(prefix).default", kind?.rawValue)
            try setSetting("\(prefix).model", model)
            try setSetting("\(prefix).effort", effort)
        }
    }

    /// Local project choices outrank a model stated in a shared repository file.
    public func applyingProjectAgentDefaults(
        to settings: RepoSettings, for repoID: RepoID
    ) throws -> RepoSettings {
        guard let chosen = try projectAgentDefaults(for: repoID) else { return settings }
        var result = settings
        result.defaultModel = "\(chosen.kind.executableName):\(chosen.model)"
        result.defaultEffort = chosen.effort
        return result
    }

    public func defaultAccount(for repoID: RepoID, kind: AgentKind) throws -> AgentAccountProfileID? {
        try setting("agent.project.\(repoID.rawValue).\(kind.rawValue).account")
            .map(AgentAccountProfileID.init)
    }

    public func setDefaultAccount(
        _ profileID: AgentAccountProfileID?, for repoID: RepoID, kind: AgentKind
    ) throws {
        if let profileID {
            guard try agentAccountProfiles().contains(where: { $0.id == profileID && $0.kind == kind }) else {
                throw AgentAccountProfileError.unknownProfile
            }
        }
        try setSetting("agent.project.\(repoID.rawValue).\(kind.rawValue).account", profileID?.rawValue)
    }

    /// Bind a conversation on first launch, so changing the project default cannot redirect its
    /// existing CLI thread to another account on a later turn.
    public func accountForLaunch(session: Session) throws -> AgentAccountProfile? {
        guard let workspaceID = session.workspaceID,
              let workspace = try workspace(id: workspaceID) else { return nil }
        let key = "agent.session.\(session.id.rawValue).account"
        let selectedID: AgentAccountProfileID?
        if let bound = try setting(key) {
            selectedID = bound == "system" ? nil : AgentAccountProfileID(bound)
        } else {
            selectedID = session.agentSessionID == nil
                ? try defaultAccount(for: workspace.repoID, kind: session.agentKind) : nil
            try setSetting(key, selectedID?.rawValue ?? "system")
        }
        guard let selectedID else { return nil }
        guard let profile = try agentAccountProfiles().first(where: {
            $0.id == selectedID && $0.kind == session.agentKind
        }) else { throw AgentAccountProfileError.unknownProfile }
        return profile
    }
}

public enum AgentAccountProfileError: Error {
    case invalidNameOrProvider
    case duplicateName
    case invalidIdentifier
    case unknownProfile
    case inUse(Int)
    case cleanupFailed(String)
}
