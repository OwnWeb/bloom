import Foundation

/// The per-installation ceiling for workspaces started by one agent.
///
/// A preference belongs to this app installation, not to a repository's shared settings file.
/// UserDefaults is thread safe, though its Swift declaration is not Sendable.
public struct WorkspaceStartPreferences: @unchecked Sendable {
    public static let maximumChildrenKey = "workspaceStart.maximumChildren"
    public static let allowedRange = 1...100

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var maximumChildren: Int {
        get {
            guard let stored = defaults.object(forKey: Self.maximumChildrenKey) as? Int else {
                return WorkspaceStartAllowance.maximumChildren
            }
            return min(max(Self.allowedRange.lowerBound, stored), Self.allowedRange.upperBound)
        }
        nonmutating set {
            defaults.set(
                min(max(Self.allowedRange.lowerBound, newValue), Self.allowedRange.upperBound),
                forKey: Self.maximumChildrenKey
            )
        }
    }
}
