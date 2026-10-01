import Foundation

/// The two movable groups in Bloom's sidebar. Project rows keep their own order within Work.
public enum SidebarTopSection: String, Sendable {
    case work
    case conversations
}

/// A preference, rather than a per-window choice, so a section stays where it was dropped.
public enum SidebarSectionOrder: String, Sendable {
    case workFirst
    case conversationsFirst

    public static let fallback = Self.workFirst
    public static let storageKey = "sidebar.sectionOrder"

    /// A heading moving one row towards the other section swaps the two groups. The order at
    /// drag start stays the reference, so pulling back reverses the swap before release.
    public func dragging(_ section: SidebarTopSection, translation: Double) -> Self {
        let first: SidebarTopSection = self == .workFirst ? .work : .conversations
        let reachesOther = section == first ? translation > 32 : translation < -32
        guard reachesOther else { return self }
        return self == .workFirst ? .conversationsFirst : .workFirst
    }
}
