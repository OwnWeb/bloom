import Foundation

/// One page of a project's branches, as runbloom.app lists them for the create sheet.
public struct CloudProjectBranches: Decodable, Sendable, Hashable {
    public struct Branch: Decodable, Sendable, Hashable {
        public var name: String
        public var isDefault: Bool

        enum CodingKeys: String, CodingKey {
            case name
            case isDefault = "is_default"
        }
    }

    public var branches: [Branch]
    public var page: Int
    public var hasMore: Bool
    /// More than a thousand branches, of which only the first thousand by name and the default can
    /// be listed or searched. A typed name is how the rest are reached.
    public var truncated: Bool

    enum CodingKeys: String, CodingKey {
        case branches, page, truncated
        case hasMore = "has_more"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        branches = try c.decode([Branch].self, forKey: .branches)
        page = try c.decodeIfPresent(Int.self, forKey: .page) ?? 1
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}
