import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// A private Cloud workspace's MCP proxy. The bearer reaches only that workspace's agent process.
public struct CloudMcpConnection: Decodable, Sendable, Hashable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public let name: String
    public let url: String
    public let bearer: String

    public init(name: String, url: String, bearer: String) {
        self.name = name
        self.url = url
        self.bearer = bearer
    }

    public var description: String { "CloudMcpConnection(name: \(name), bearer: [REDACTED])" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["description": description]) }
}

/// Launch configuration for the two CLIs. A token never appears in argv.
public enum CloudMcpConfiguration {
    public static func writeClaude(
        _ connections: [CloudMcpConnection], sessionID: SessionID, directory: String,
        sharedGroup: String? = nil
    ) throws -> String? {
        let path = (directory as NSString).appendingPathComponent("\(sessionID).json")
        guard !connections.isEmpty else {
            try? FileManager.default.removeItem(atPath: path)
            return nil
        }

        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o2750]
        )
        let groupID: gid_t? = try sharedGroup.map { name in
            guard let group = name.withCString({ getgrnam($0) }) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let groupID = group.pointee.gr_gid
            guard chown(directory, uid_t.max, groupID) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
            return groupID
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o2750], ofItemAtPath: directory)

        var servers: [String: Any] = [:]
        for connection in connections where Self.valid(connection) {
            servers[connection.name] = [
                "type": "http",
                "url": connection.url,
                "headers": ["Authorization": "Bearer \(connection.bearer)"],
            ]
        }
        guard !servers.isEmpty else {
            try? FileManager.default.removeItem(atPath: path)
            return nil
        }

        let data = try JSONSerialization.data(withJSONObject: ["mcpServers": servers], options: [.sortedKeys])
        let temporaryPath = path + "." + UUID().uuidString + ".tmp"
        let descriptor = open(temporaryPath, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer {
            close(descriptor)
            unlink(temporaryPath)
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                #if canImport(Glibc)
                let count = Glibc.write(descriptor, base.advanced(by: written), bytes.count - written)
                #else
                let count = Darwin.write(descriptor, base.advanced(by: written), bytes.count - written)
                #endif
                guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
                written += count
            }
        }
        if let groupID, fchown(descriptor, uid_t.max, groupID) != 0 {
            throw CocoaError(.fileWriteUnknown)
        }
        guard fchmod(descriptor, 0o640) == 0, rename(temporaryPath, path) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        return path
    }

    public static func codexArguments(_ connections: [CloudMcpConnection]) -> [String] {
        connections.filter(valid).flatMap { connection in
            let key = "mcp_servers.\(connection.name)"
            return [
                "-c", "\(key).url=\(BridgeRegistration.tomlString(connection.url))",
                "-c", "\(key).bearer_token_env_var=\(BridgeRegistration.tomlString(environmentKey(connection.name)))",
            ]
        }
    }

    public static func codexEnvironment(_ connections: [CloudMcpConnection]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: connections.filter(valid).map { (environmentKey($0.name), $0.bearer) })
    }

    private static func environmentKey(_ name: String) -> String {
        "BLOOM_MCP_\(name.uppercased().replacingOccurrences(of: "-", with: "_"))_TOKEN"
    }

    private static func valid(_ connection: CloudMcpConnection) -> Bool {
        connection.name.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) != nil
            && URL(string: connection.url)?.scheme == "https"
            && URL(string: connection.url)?.host != nil
            && !connection.bearer.isEmpty
    }
}
