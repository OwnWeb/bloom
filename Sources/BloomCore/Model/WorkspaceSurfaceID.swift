import Foundation

/// Which workspace a surface is, for the stores that are keyed by one.
///
/// Two cases rather than one string, for `SidebarSelection`'s reason: a Cloud id and a local id are
/// drawn from different places and a lookup that took either would find nothing and say nothing.
public enum WorkspaceSurfaceID: Hashable, Sendable, Codable {
    case local(WorkspaceID)
    case cloud(CloudWorkspaceID)

    /// The key a per-workspace store files this under.
    ///
    /// **A local workspace's key is its id and nothing else,** which is what lets the tab stores be
    /// keyed by this without a migration: every `center.tabs.`, `center.strip.` and viewed mark
    /// written before this type existed is still found by the same string. A Cloud workspace's is
    /// namespaced, so one whose id happened to match a local one cannot read its tabs, its viewed
    /// marks or its drafts. `WorkspaceSurfaceIDTests` pins both halves.
    public var storageKey: String {
        switch self {
        case .local(let id): id.rawValue
        case .cloud(let id): "cloud:" + id.rawValue
        }
    }

    public var local: WorkspaceID? {
        if case .local(let id) = self { return id }
        return nil
    }

    /// Read back from a key, which is how a stored record names the workspace it belongs to.
    public init(storageKey: String) {
        if let id = storageKey.strippingCloudPrefix {
            self = .cloud(CloudWorkspaceID(id))
        } else {
            self = .local(WorkspaceID(storageKey))
        }
    }

    /// One string, not a tagged pair, and that is what makes this change free: a `WorkspaceID`
    /// encodes as its bare raw value, so every `CenterTab` written before this type existed reads
    /// back as the local workspace it named. `WorkspaceSurfaceIDTests` pins that.
    public init(from decoder: any Decoder) throws {
        self.init(storageKey: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageKey)
    }
}

private extension String {
    /// The id inside a Cloud key, or nil for a local one. The prefix is a colon, which a workspace
    /// id never contains.
    var strippingCloudPrefix: String? {
        hasPrefix("cloud:") ? String(dropFirst("cloud:".count)) : nil
    }
}
