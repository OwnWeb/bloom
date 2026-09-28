import Foundation

/// One hunk cut out of a file's patch, as a patch of its own that `git apply` will take.
///
/// **Sliced out of git's own text, never rebuilt from the parsed lines.** `DiffParser` drops each
/// line's marker, folds the "\ No newline at end of file" marker into a kind of its own, and
/// decodes the bytes, so a hunk written back from a `DiffHunk` is a hunk that has been through
/// three lossy steps, and a reverse patch that differs from the file by one carriage return is a
/// patch that does not apply. The parse is used only to find which stretch of the text is the
/// hunk the reader pressed on.
///
/// **The header is two lines, both derived from the `+++` line.** Git's own header for a renamed
/// file says "rename from" and "rename to", and a mode change says "old mode" and "new mode".
/// Reversed, those undo the rename and the mode along with the one hunk, which is a discard of
/// the whole file's metadata dressed up as a discard of four lines. The destination path is the
/// file as it is in the worktree, so both sides are named after it and git reads the patch as a
/// plain change to one file. Git quotes a path it has to, as `"b/moved \303\251.txt"`, and the
/// prefix swap below keeps that quoting intact.
public enum HunkPatch {
    /// A patch holding only the hunk of `patch` that matches `hunk`, or nil when `patch` has no
    /// such hunk any more.
    ///
    /// The match is on coordinates and on every line's kind and text. Not on `DiffLine.index`,
    /// which counts from the top of the file and moves when a hunk above this one grows. Coordinates
    /// that have moved are a refusal rather than a search, because they mean the file changed
    /// under the diff the reader was looking at, and that is exactly the time not to guess.
    public static func isolate(_ hunk: DiffHunk, from patch: String) -> String? {
        let files = DiffParser.parse(patch)
        guard files.count == 1, let file = files.first else { return nil }
        guard let position = file.hunks.firstIndex(where: { matches($0, hunk) }) else { return nil }

        let lines = patch.components(separatedBy: "\n")
        guard let newPath = lines.first(where: { $0.hasPrefix("+++ ") }),
              let oldPath = oldSide(of: newPath) else { return nil }

        let starts = lines.indices.filter { lines[$0].hasPrefix("@@") }
        // Every hunk header the parser counted is a line starting with `@@`, and no body line can
        // start with one, because a body line starts with its marker. If the two counts disagree
        // the text is not what the parse was of, and a slice by position would be a different hunk.
        guard starts.count == file.hunks.count else { return nil }

        let start = starts[position]
        var end = position + 1 < starts.count ? starts[position + 1] : lines.count
        // The patch ends in a newline, which `components` reads as one empty line after it.
        if end == lines.count, lines.last == "" { end -= 1 }
        let body = lines[start..<end]

        return ([oldPath, newPath] + body).joined(separator: "\n") + "\n"
    }

    private static func matches(_ lhs: DiffHunk, _ rhs: DiffHunk) -> Bool {
        lhs.oldStart == rhs.oldStart && lhs.oldCount == rhs.oldCount
            && lhs.newStart == rhs.newStart && lhs.newCount == rhs.newCount
            && lhs.lines.map(\.kind) == rhs.lines.map(\.kind)
            && lhs.lines.map(\.text) == rhs.lines.map(\.text)
    }

    /// `+++ b/path` as `--- a/path`, keeping git's quoting and the trailing tab it adds to a name
    /// with a space in it. Nil for `+++ /dev/null`: a deleted file has no worktree side to discard
    /// a hunk from.
    static func oldSide(of newPath: String) -> String? {
        let name = newPath.dropFirst("+++ ".count)
        if name.hasPrefix("\"b/") { return "--- \"a/" + name.dropFirst(3) }
        if name.hasPrefix("b/") { return "--- a/" + name.dropFirst(2) }
        return nil
    }
}
