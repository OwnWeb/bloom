import Foundation

/// Whether a branch name is one runbloom.app will take, by the rules of
/// `git check-ref-format --branch`, which is what it validates with.
///
/// Checked while typing so the create sheet can say what is wrong before a round trip. runbloom.app
/// checks again, and its answer wins.
public enum CloudBranchName {
    /// Nil for a good name, otherwise what is wrong with it.
    public static func problem(_ name: String) -> String? {
        if name.isEmpty { return "Enter a branch name." }
        if name.hasPrefix("-") { return "A branch name cannot start with a hyphen." }
        if name.hasPrefix("/") || name.hasSuffix("/") { return "A branch name cannot start or end with a slash." }
        if name.hasSuffix(".") { return "A branch name cannot end with a full stop." }
        if name.hasSuffix(".lock") { return "A branch name cannot end with .lock." }
        if name == "@" { return "A branch cannot be called @." }
        if name.contains("..") { return "A branch name cannot contain two full stops in a row." }
        if name.contains("//") { return "A branch name cannot contain two slashes in a row." }
        if name.contains("@{") { return "A branch name cannot contain @{." }
        if name.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return "No part of a branch name can start with a full stop." }
        let forbidden = CharacterSet(charactersIn: " ~^:?*[\\").union(.controlCharacters)
        if name.unicodeScalars.contains(where: forbidden.contains) {
            return "A branch name cannot contain spaces or any of ~ ^ : ? * [ \\."
        }
        return nil
    }

    /// How much of a name a branch keeps, before the prefix.
    ///
    /// The same sixty `Git.slug` caps a local branch at, and for the same reason: a ref is typed,
    /// read and pasted by people. The name it comes from is capped at 72 by `Git.title`, which cuts
    /// at the last space inside that, so an ordinary sentence never reaches this. What does reach
    /// it is a first line with no space in it at all, which keeps its whole 72 character prefix and
    /// would otherwise arrive here as seventy characters of one word.
    public static let slugLimit = 60

    /// A branch name suggested from a workspace name: lowercase words joined by hyphens under the
    /// person's prefix, as `freek/queue-retries`.
    public static func suggestion(for workspaceName: String, prefix: String?) -> String {
        let words = workspaceName.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        let slug = capped(String(words).split(separator: " ").joined(separator: "-"))
        guard !slug.isEmpty else { return "" }
        guard let prefix, !prefix.isEmpty else { return slug }
        return "\(prefix)/\(slug)"
    }

    /// Cut at a hyphen inside the limit where there is one, so a branch ends on a whole word, and
    /// hard otherwise, which is the single-token case this exists for. A trailing hyphen is not a
    /// word boundary anybody wants to read, so it comes off.
    private static func capped(_ slug: String) -> String {
        guard slug.count > slugLimit else { return slug }
        let cut = slug.prefix(slugLimit)
        let kept = cut.lastIndex(of: "-").map { String(cut[..<$0]) } ?? String(cut)
        return kept.hasSuffix("-") ? String(kept.dropLast()) : kept
    }
}
