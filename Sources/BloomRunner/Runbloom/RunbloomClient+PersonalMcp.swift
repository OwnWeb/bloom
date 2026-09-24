import BloomCore
import Foundation

extension RunbloomClient {
    public func personalMcpConnections() async throws -> [CloudMcpConnection] {
        struct Answer: Decodable { let connections: [CloudMcpConnection] }
        let data = try await send(.GET, "/personal-mcp-connections", expecting: [200])
        return try decode(Answer.self, data, status: 200).connections
    }
}
