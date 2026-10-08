import Foundation

/// Which forge a repository's pull requests are asked of: GitLab only on positive evidence,
/// GitHub otherwise. A GitHub remote anywhere wins, and nobody is asked. `git.forge` in a
/// settings file overrules detection.
public enum ForgeRouting {
    public enum Decision: Sendable, Equatable {
        case forge(Forge)
        /// Neither GitHub nor gitlab.com: GitLab only if glab is signed in to the host.
        case askGlab(host: String)
    }

    public static func decide(declared: Forge?, baseRemoteURL: String?, remoteURLs: [String]) -> Decision {
        if let declared { return .forge(declared) }
        guard let base = GitHub.repositoryHost(baseRemoteURL) else { return .forge(.gitHub) }
        if isGitHub(base) || remoteURLs.compactMap({ GitHub.repositoryHost($0) }).contains(where: isGitHub) {
            return .forge(.gitHub)
        }
        if isGitLabCom(base) { return .forge(.gitLab) }
        return .askGlab(host: base)
    }

    /// Any host naming GitHub, so Enterprise hosts and SSH aliases like `github-work` are never
    /// probed with glab.
    static func isGitHub(_ host: String) -> Bool {
        host.contains("github")
    }

    static func isGitLabCom(_ host: String) -> Bool {
        host == "gitlab.com" || host.hasSuffix(".gitlab.com")
    }
}

/// `ForgeRouting` applied to a directory, remembered until git's config or a settings file changes.
public enum ForgeResolver {
    private static let resolutions = ForgeResolutions()

    public static func client(for directory: String) async -> any ForgeClient.Type {
        switch await forge(for: directory) {
        case .gitHub: GitHubForge.self
        case .gitLab: GitLab.self
        }
    }

    public static func forge(for directory: String) async -> Forge {
        let paths = Git.repositoryPaths(in: directory)
        let checkout = mainCheckout(paths) ?? directory
        let configPath = paths.map { ($0.commonDirectory as NSString).appendingPathComponent("config") }
        let fingerprint = fingerprint(of: [configPath].compactMap { $0 } + SettingsLoader.candidatePaths(repo: checkout))
        if let known = await resolutions.forge(for: directory, fingerprint: fingerprint) { return known }

        let forge = await resolve(directory: directory, checkout: checkout, configPath: configPath)
        await resolutions.store(forge, for: directory, fingerprint: fingerprint)
        return forge
    }

    private static func resolve(directory: String, checkout: String, configPath: String?) async -> Forge {
        if let declared = SettingsLoader.load(repo: checkout).forge { return declared }
        // Settled from the config file's text where possible, so a GitHub user pays no process.
        let written = configPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
        let hosts = remoteURLs(in: written).compactMap { GitHub.repositoryHost($0) }
        if hosts.contains(where: ForgeRouting.isGitHub) { return .gitHub }
        if !hosts.contains(where: ForgeRouting.isGitLabCom), GlabSignIn.isInstalled() == false { return .gitHub }

        let config = (try? await Git.repositoryConfiguration(in: directory)) ?? [:]
        let context = try? await Git.repositoryContext(in: directory)
        let remotes = config.filter { $0.key.hasPrefix("remote.") && $0.key.hasSuffix(".url") }.map(\.value)
        switch ForgeRouting.decide(declared: nil, baseRemoteURL: context?.baseRemoteURL, remoteURLs: remotes) {
        case .forge(let decided): return decided
        case .askGlab(let host): return await GlabSignIn.shared.isSignedIn(to: host) ? .gitLab : .gitHub
        }
    }

    /// The `url = ` values of a git config file, without git. Includes and `insteadOf` are not
    /// followed; anything they hide reaches the full resolution instead.
    static func remoteURLs(in config: String) -> [String] {
        config.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0].lowercased() == "url" else { return nil }
            return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
    }

    /// The project's own checkout, where `settings.local.toml` lives.
    static func mainCheckout(_ paths: GitRepositoryPaths?) -> String? {
        guard let common = paths?.commonDirectory, (common as NSString).lastPathComponent == ".git" else { return nil }
        return (common as NSString).deletingLastPathComponent
    }

    private static func fingerprint(of paths: [String]) -> [Date?] {
        paths.map { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }
    }
}

private actor ForgeResolutions {
    private var entries: [String: (fingerprint: [Date?], forge: Forge)] = [:]

    func forge(for directory: String, fingerprint: [Date?]) -> Forge? {
        guard let entry = entries[directory], entry.fingerprint == fingerprint else { return nil }
        return entry.forge
    }

    func store(_ forge: Forge, for directory: String, fingerprint: [Date?]) {
        entries[directory] = (fingerprint, forge)
    }
}

/// Whether glab is signed in to a host. One probe per host at a time; a yes is kept for the
/// launch, a no only for a few minutes, because a VPN that was down comes back.
actor GlabSignIn {
    static let shared = GlabSignIn()
    private static let timeout = Duration.seconds(10)
    private static let refusalLifetime = Duration.seconds(300)

    private var answers: [String: (signedIn: Bool, at: ContinuousClock.Instant)] = [:]
    private var probes: [String: Task<Bool, Never>] = [:]

    static func isInstalled() -> Bool {
        GitLab.commandOverride != nil || Shell.which("glab") != nil
    }

    func isSignedIn(to host: String) async -> Bool {
        if let known = answers[host], known.signedIn || known.at.duration(to: .now) < Self.refusalLifetime {
            return known.signedIn
        }
        if let running = probes[host] { return await running.value }
        let probe = Task { await Self.probe(host) }
        probes[host] = probe
        let answer = await probe.value
        probes[host] = nil
        answers[host] = (answer, .now)
        return answer
    }

    private static func probe(_ host: String) async -> Bool {
        let arguments = ["auth", "status", "--hostname", host]
        if let override = GitLab.commandOverride {
            return (try? await override(arguments, nil))?.ok ?? false
        }
        guard Shell.which("glab") != nil else { return false }
        return (try? await Shell.run("glab", arguments, timeout: timeout))?.ok ?? false
    }
}
