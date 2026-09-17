import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `bloom-runner git-credential get` and `bloom-runner gh-token`, run by git and by the `gh`
/// wrapper on the machine.
///
/// git is configured at start with this as the credential helper for github.com, so `git clone`,
/// `fetch` and `push` ask here and nothing long-lived is ever on disk. Everything else git sends a
/// helper (`store`, `erase`) is ignored, because there is nothing to store.
enum GitCredentialCommand {
    static func run(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) async -> Int32 {
        switch arguments.first {
        case "git-credential":
            guard arguments.dropFirst().first == "get" else { return 0 }
            let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            let fields = parse(input)
            guard fields["host"] == "github.com", let path = fields["path"], let repository = repository(fromPath: path) else { return 0 }
            guard let answer = await ask(repository: repository, environment: environment) else { return 1 }
            print("username=\(answer.username)")
            print("password=\(answer.token)")
            return 0
        case "gh-token":
            guard let repository = environment["BLOOM_REPOSITORY"], let answer = await ask(repository: repository, environment: environment) else {
                return 1
            }
            print(answer.token)
            return 0
        default:
            return 64
        }
    }

    static func parse(_ input: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in input.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
        }
        return fields
    }

    /// `owner/name` out of git's `path`, which is `owner/name.git` or `owner/name`.
    static func repository(fromPath path: String) -> String? {
        var trimmed = path
        if trimmed.hasSuffix(".git") { trimmed.removeLast(4) }
        let parts = trimmed.split(separator: "/")
        guard parts.count == 2 else { return nil }
        return parts.joined(separator: "/")
    }

    private static func ask(repository: String, environment: [String: String]) async -> GitCredentialRoute.Answer? {
        let data = environment["BLOOM_DATA_DIR"] ?? (environment["HOME"] ?? NSHomeDirectory()) + "/.bloom"
        guard let secret = try? String(contentsOfFile: data + "/local-secret", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let port = environment["BLOOM_RUNNER_PORT"] ?? "8081"
        guard let url = URL(string: "http://127.0.0.1:\(port)/_bloom/local/git-credentials") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue(secret, forHTTPHeaderField: GitCredentialRoute.secretHeader.rawName)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(GitCredentialRoute.Asked(
            repository: repository, chatID: environment["BLOOM_CHAT_ID"], turnID: environment["BLOOM_TURN_ID"],
            terminal: environment["BLOOM_TERMINAL"]
        ))
        guard let (body, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(GitCredentialRoute.Answer.self, from: body)
    }
}
