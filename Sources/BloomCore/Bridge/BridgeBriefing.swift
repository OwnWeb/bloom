import Foundation

/// Formats the tools named by an MCP connection's initialization instructions.
public enum BridgeBriefing {
    public static func tools(_ names: [String]) -> String {
        guard !names.isEmpty else { return "" }
        return "\n\nThe tools on this connection are the whole of what Bloom offers here: "
            + names.sorted().joined(separator: ", ") + "."
    }
}
