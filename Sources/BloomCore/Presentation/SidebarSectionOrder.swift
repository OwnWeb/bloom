import Foundation

/// The two movable groups in Bloom's sidebar. Project rows keep their own order within Work.
public enum SidebarTopSection: String, Sendable {
    case work
    case conversations

    public var dragToken: String { "bloom.sidebar.section.\(rawValue)" }

    public init?(dragToken: String) {
        let prefix = "bloom.sidebar.section."
        guard dragToken.hasPrefix(prefix) else { return nil }
        self.init(rawValue: String(dragToken.dropFirst(prefix.count)))
    }
}

/// A preference, rather than a per-window choice, so a section stays where it was dropped.
public enum SidebarSectionOrder: String, Sendable {
    case workFirst
    case conversationsFirst

    public static let fallback = Self.workFirst
    public static let storageKey = "sidebar.sectionOrder"

    public static func moving(_ source: SidebarTopSection, onto target: SidebarTopSection) -> Self? {
        guard source != target else { return nil }
        return source == .conversations ? .conversationsFirst : .workFirst
    }
}
