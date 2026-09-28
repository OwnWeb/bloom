import Foundation

/// The variables given to setup, archive and run scripts under both prefixes.
public struct WorkspaceScriptVariables: Sendable, Hashable {
    public var workspaceName: String
    public var workspaceID: WorkspaceID
    public var workspacePath: String
    public var projectName: String
    public var rootPath: String
    public var defaultBranch: String
    public var port: Int
    /// Where a browser pane's address can be written.
    public var urlFile: String?

    public init(
        workspaceName: String, workspaceID: WorkspaceID, workspacePath: String, projectName: String,
        rootPath: String, defaultBranch: String, port: Int, urlFile: String? = nil
    ) {
        self.workspaceName = workspaceName
        self.workspaceID = workspaceID
        self.workspacePath = workspacePath
        self.projectName = projectName
        self.rootPath = rootPath
        self.defaultBranch = defaultBranch
        self.port = port
        self.urlFile = urlFile
    }

    /// Every name under both prefixes, with the same value, so a script written against either
    /// sees the same workspace.
    public var environment: [String: String] {
        var pairs: [(String, String)] = [
            ("IS_LOCAL", "1"),
            ("WORKSPACE_NAME", workspaceName),
            ("WORKSPACE_ID", workspaceID.rawValue),
            ("WORKSPACE_PATH", workspacePath),
            ("PROJECT_NAME", projectName),
            ("ROOT_PATH", rootPath),
            ("DEFAULT_BRANCH", defaultBranch),
            ("PORT", String(port)),
        ]
        if let urlFile { pairs.append(("URL_FILE", urlFile)) }
        var environment: [String: String] = [:]
        for (key, value) in pairs {
            for prefix in WorkspaceManager.environmentPrefixes {
                environment["\(prefix)_\(key)"] = value
            }
        }
        return environment
    }

    /// A branch as a name a script can use: slashes are not allowed in most of the places it ends up.
    public static func workspaceName(branch: String) -> String {
        branch.replacingOccurrences(of: "/", with: "-")
    }

    /// A name a script may paste into a database name, a container name or a shell identifier
    /// without quoting: everything outside ASCII letters and digits becomes an underscore.
    public static func identifier(_ source: String) -> String {
        let cleaned = String(source.map { character in
            character.isASCII && (character.isLetter || character.isNumber) ? character : "_"
        })
        return cleaned.isEmpty ? "project" : cleaned
    }
}
