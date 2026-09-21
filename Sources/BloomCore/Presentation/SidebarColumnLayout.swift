import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The two leading columns shared by project headers and the rows beneath them.
///
/// A project puts its disclosure control first and its icon after one gap. A workspace reuses
/// those same coordinates: its status occupies the disclosure column and its text begins where
/// the project icon begins. Keeping that relationship in one value stops an idle row, whose
/// status is clear, from gaining a different text inset from an unread or running row.
public struct SidebarColumnLayout: Equatable, Sendable {
    public var disclosureWidth: CGFloat
    public var spacing: CGFloat

    public init(disclosureWidth: CGFloat, spacing: CGFloat) {
        self.disclosureWidth = disclosureWidth
        self.spacing = spacing
    }

    /// The fixed width reserved for every workspace status, including an empty status.
    public var indicatorWidth: CGFloat { disclosureWidth }

    /// The leading edge shared by the project icon and workspace text.
    public var primaryContentLeading: CGFloat { disclosureWidth + spacing }

    /// Workspace rows no longer need a second inset beyond the list's own inset.
    public var workspaceIndent: CGFloat { 0 }

    /// One visible hierarchy step for rows nested beneath a workspace.
    public var childIndent: CGFloat { disclosureWidth }
}
