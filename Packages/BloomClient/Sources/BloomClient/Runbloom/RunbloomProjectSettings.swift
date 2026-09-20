import Foundation

/// The project settings fields a client needs to present and refresh server-discovered artwork.
/// Every URL remains server supplied. Clients do not derive an icon or refresh route from IDs.
public struct RunbloomProjectSettings: Codable, Sendable, Hashable {
    public var id: String
    public var repository: String
    public var iconURL: String?
    public var icon: Icon

    public init(id: String, repository: String, iconURL: String? = nil, icon: Icon) {
        self.id = id
        self.repository = repository
        self.iconURL = iconURL
        self.icon = icon
    }

    enum CodingKeys: String, CodingKey {
        case id, repository, icon
        case iconURL = "icon_url"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        repository = try container.decode(String.self, forKey: .repository)
        iconURL = try? container.decodeIfPresent(String.self, forKey: .iconURL)
        icon = (try? container.decode(Icon.self, forKey: .icon)) ?? Icon(status: nil)
    }

    public struct Icon: Codable, Sendable, Hashable {
        /// `pending`, `available`, or `missing`. Kept as a string so a future server state does not
        /// make the settings unreadable to an older client.
        public var status: String?
        public var checkedAt: String?
        public var refreshURL: String?

        public init(status: String?, checkedAt: String? = nil, refreshURL: String? = nil) {
            self.status = status
            self.checkedAt = checkedAt
            self.refreshURL = refreshURL
        }

        enum CodingKeys: String, CodingKey {
            case status
            case checkedAt = "checked_at"
            case refreshURL = "refresh_url"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try? container.decodeIfPresent(String.self, forKey: .status)
            checkedAt = try? container.decodeIfPresent(String.self, forKey: .checkedAt)
            refreshURL = try? container.decodeIfPresent(String.self, forKey: .refreshURL)
        }
    }
}
