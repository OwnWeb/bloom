import Foundation

/// A Cloud workspace, by runbloom.app's id for it (a lowercase ULID).
///
/// Its own type rather than a `WorkspaceID`, because a Cloud workspace is not a row in this Mac's
/// database: it has no worktree here, no sessions in the store and no terminal tab rows, and every
/// path that takes a `WorkspaceID` goes looking for one of those. A Cloud id handed to one of them
/// would compile and find nothing, which is the failure `Identifier` exists to make impossible.
public struct CloudWorkspaceID: Identifier {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}
