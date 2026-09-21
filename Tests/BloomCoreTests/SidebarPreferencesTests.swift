import Foundation
import Testing
@testable import BloomCore

@Suite("Sidebar preferences")
struct SidebarPreferencesTests {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let name = "bloom.sidebar.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (defaults, name)
    }

    @Test("Diff stats are hidden until the user asks for them")
    func diffStatsStartHidden() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(SidebarPreferences.showsDiffStats(in: defaults) == false)
        #expect(defaults.object(forKey: SidebarPreferences.showsDiffStatsKey) == nil)
    }

    @Test("The diff stat choice persists in the sidebar setting")
    func diffStatsChoicePersists() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set(true, forKey: SidebarPreferences.showsDiffStatsKey)

        #expect(SidebarPreferences.showsDiffStats(in: defaults))
        #expect(SidebarPreferences.showsDiffStatsKey == "sidebar.showsDiffStats")
    }
}
