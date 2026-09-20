import Foundation

/// One line of the workspace's code that matched a `search_code` query.
public struct CodeMatchRecord: Codable, Sendable, Hashable {
    /// Relative to the worktree, as `files` lists it.
    public var path: String
    /// From one.
    public var line: Int
    /// Where the match starts on the line, from one, in UTF-16 code units, which is what a
    /// JavaScript string and `NSRange` both count in.
    public var column: Int
    /// The line, cut at 400 characters.
    public var text: String

    public init(path: String, line: Int, column: Int, text: String) {
        self.path = path
        self.line = line
        self.column = column
        self.text = text
    }
}
