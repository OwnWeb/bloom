import Foundation

/// How this project's owner prefers to merge a workspace branch into its local base.
public enum LocalMergeMode: String, CaseIterable, Sendable {
    case agent
    case direct

    public var label: String {
        switch self {
        case .agent: "Ask agent"
        case .direct: "Merge directly"
        }
    }
}

/// A UI preference in Bloom's store, so choosing a mode never dirties a checkout.
public enum LocalMergeModeChoice {
    public static let fallback = LocalMergeMode.agent

    public static func key(repoID: RepoID) -> String {
        "repo.\(repoID).localMergeMode"
    }

    public static func resolve(_ stored: String?) -> LocalMergeMode {
        stored.flatMap(LocalMergeMode.init(rawValue:)) ?? fallback
    }

    public static func load(repoID: RepoID, from store: Store) async -> LocalMergeMode {
        resolve(try? await store.setting(key(repoID: repoID)))
    }

    public static func save(_ mode: LocalMergeMode, repoID: RepoID, to store: Store) async {
        try? await store.setSetting(key(repoID: repoID), mode.rawValue)
    }
}
