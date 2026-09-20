import BloomClient
import BloomCore
import Foundation
import Observation

/// Authenticated project artwork and discovery state for this signed-in account.
///
/// The cache key is the server's team and project authority boundary, never a repository name.
/// The revisioned URL is part of every entry, so duplicate names do not collide and a replacement
/// begins a new load. A late answer for an older revision cannot replace the current one.
@MainActor
@Observable
final class CloudProjectIcons {
    typealias Key = CloudProjectIconLoadState.Key

    private enum ArtworkAnswer {
        case data(Data)
        case permanentFailure
        case transientFailure

        var isTransient: Bool {
            if case .transientFailure = self { true } else { false }
        }
    }

    private enum ArtworkEntry {
        case loading(
            url: String,
            ticket: CloudProjectIconLoadState.Ticket,
            task: Task<ArtworkAnswer, Never>
        )
        case loaded(url: String, artwork: RepoArtwork?)
        case retryable(url: String)

        var url: String {
            switch self {
            case .loading(let url, _, _), .loaded(let url, _), .retryable(let url): url
            }
        }
    }

    @ObservationIgnored private var artwork: [Key: ArtworkEntry] = [:]
    @ObservationIgnored private var settingsEndpoints: [Key: String] = [:]
    @ObservationIgnored private var settingsLoads: [Key: (
        endpoint: String, generation: UInt64, task: Task<RunbloomProjectSettings?, Never>
    )] = [:]
    @ObservationIgnored private var refreshingSettings: Set<Key> = []
    @ObservationIgnored private var settingsGenerations: [Key: UInt64] = [:]
    @ObservationIgnored private var nextSettingsGeneration: UInt64 = 0
    private var loadState = CloudProjectIconLoadState()
    private var settings: [Key: RunbloomProjectSettings] = [:]

    func reset() {
        for entry in artwork.values {
            if case .loading(_, _, let task) = entry { task.cancel() }
        }
        artwork.removeAll()
        settingsEndpoints.removeAll()
        for load in settingsLoads.values { load.task.cancel() }
        settingsLoads.removeAll()
        refreshingSettings.removeAll()
        settingsGenerations.removeAll()
        settings.removeAll()
        loadState.reset()
    }

    func effectiveURL(for key: Key, listedURL: String?) -> String? {
        // The polled list is the current presentation contract, including an explicit nil after
        // artwork is removed. Settings supplies status and refresh capability, not an override
        // that could keep a stale revision alive after the list has moved on.
        listedURL
    }

    func state(for key: Key, settingsEndpoint: String?) -> RunbloomProjectSettings.Icon? {
        guard let settingsEndpoint, settingsEndpoints[key] == settingsEndpoint else { return nil }
        return settings[key]?.icon
    }

    func requestRevision(for key: Key) -> Int {
        loadState.retryRevision(for: key)
    }

    /// Reconciles the cache with the current nullable revision URL. A normal list poll is also the
    /// retry clock for transient failures, avoiding a hot loop while allowing an outage to heal.
    func reconcileArtwork(for key: Key, listedURL: String?) {
        guard let listedURL else {
            if case .loading(_, _, let task) = artwork[key] { task.cancel() }
            artwork.removeValue(forKey: key)
            loadState.clear(key)
            return
        }
        guard let entry = artwork[key] else { return }
        guard entry.url == listedURL else {
            if case .loading(_, _, let task) = entry { task.cancel() }
            artwork.removeValue(forKey: key)
            loadState.clear(key)
            return
        }
        guard case .retryable = entry, loadState.retryTransient(key: key, url: listedURL) else { return }
        artwork.removeValue(forKey: key)
    }

    func loadSettings(for key: Key, endpoint: String?, api: RunbloomAPI, force: Bool = false) async {
        guard let endpoint else {
            _ = beginSettingsOperation(for: key)
            settingsLoads.removeValue(forKey: key)?.task.cancel()
            settingsEndpoints.removeValue(forKey: key)
            settings.removeValue(forKey: key)
            return
        }
        if let current = settingsEndpoints[key], current != endpoint {
            _ = beginSettingsOperation(for: key)
            settingsLoads.removeValue(forKey: key)?.task.cancel()
            settingsEndpoints.removeValue(forKey: key)
            settings.removeValue(forKey: key)
        }
        // The refresh response is the state immediately after the requested transition. A poll
        // that began beside it could only race that answer with the state from just before it.
        guard !refreshingSettings.contains(key) else { return }
        guard force || settingsEndpoints[key] != endpoint else { return }
        let task: Task<RunbloomProjectSettings?, Never>
        let generation: UInt64
        if let load = settingsLoads[key], load.endpoint == endpoint {
            task = load.task
            generation = load.generation
        } else {
            settingsLoads.removeValue(forKey: key)?.task.cancel()
            if settingsEndpoints[key] != endpoint {
                settingsEndpoints.removeValue(forKey: key)
                settings.removeValue(forKey: key)
            }
            generation = beginSettingsOperation(for: key)
            task = Task { try? await api.projectSettings(at: endpoint) }
            settingsLoads[key] = (endpoint, generation, task)
        }
        let answer = await task.value
        guard let current = settingsLoads[key], current.endpoint == endpoint,
              current.generation == generation, settingsGenerations[key] == generation else { return }
        settingsLoads.removeValue(forKey: key)
        guard let answer, answer.id == key.projectID.rawValue else {
            return
        }
        settingsEndpoints[key] = endpoint
        settings[key] = answer
    }

    func refresh(for key: Key, api: RunbloomAPI) async throws {
        guard let authorityEndpoint = settingsEndpoints[key],
              let endpoint = settings[key]?.icon.refreshURL,
              !refreshingSettings.contains(key) else { return }
        settingsLoads.removeValue(forKey: key)?.task.cancel()
        let generation = beginSettingsOperation(for: key)
        refreshingSettings.insert(key)
        defer { refreshingSettings.remove(key) }
        let answer = try await api.refreshProjectIcon(at: endpoint)
        guard settingsGenerations[key] == generation,
              settingsEndpoints[key] == authorityEndpoint,
              settings[key]?.icon.refreshURL == endpoint else { return }
        guard answer.id == key.projectID.rawValue else {
            throw RunbloomRefusal(
                status: 200, code: "wrong_project",
                message: "runbloom.app returned project icon settings for another project."
            )
        }
        settings[key] = answer
    }

    private func beginSettingsOperation(for key: Key) -> UInt64 {
        nextSettingsGeneration &+= 1
        settingsGenerations[key] = nextSettingsGeneration
        return nextSettingsGeneration
    }

    func artwork(for key: Key, listedURL: String?, api: RunbloomAPI) async -> RepoArtwork? {
        guard let url = effectiveURL(for: key, listedURL: listedURL) else { return nil }
        if let entry = artwork[key], entry.url == url {
            switch entry {
            case .loaded(_, let result): return result
            case .loading(_, let ticket, let task): return await resolved(task, ticket: ticket)
            case .retryable: return nil
            }
        }

        let ticket = loadState.begin(key: key, url: url)
        let task = Task { await Self.download(api: api, url: url) }
        artwork[key] = .loading(url: url, ticket: ticket, task: task)
        return await resolved(task, ticket: ticket)
    }

    private func resolved(
        _ task: Task<ArtworkAnswer, Never>, ticket: CloudProjectIconLoadState.Ticket
    ) async -> RepoArtwork? {
        let answer = await task.value
        let result: RepoArtwork?
        let completion: CloudProjectIconLoadState.Completion
        switch answer {
        case .data(let data):
            result = RepoIconArt.artwork(data: data)
            completion = result == nil ? .permanentFallback : .artwork
        case .permanentFailure:
            result = nil
            completion = .permanentFallback
        case .transientFailure:
            result = nil
            completion = .transientFailure
        }
        // Another revision or account may have taken the authority slot while this was suspended.
        guard loadState.finish(ticket, as: completion) else { return nil }
        artwork[ticket.key] = answer.isTransient
            ? .retryable(url: ticket.url)
            : .loaded(url: ticket.url, artwork: result)
        return result
    }

    private static func download(api: RunbloomAPI, url: String) async -> ArtworkAnswer {
        do {
            return .data(try await api.projectIcon(at: url))
        } catch {
            return ProjectIconFailurePolicy.shouldRetry(error) ? .transientFailure : .permanentFailure
        }
    }
}
