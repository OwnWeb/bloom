import Foundation

/// Preferences that control how much detail the sidebar draws.
public enum SidebarPreferences {
    /// The setting shared by the sidebar rows and the switch in Settings.
    public static let showsDiffStatsKey = "sidebar.showsDiffStats"
    public static let showsDiffStatsByDefault = false

    public static func showsDiffStats(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: showsDiffStatsKey) as? Bool ?? showsDiffStatsByDefault
    }
}
