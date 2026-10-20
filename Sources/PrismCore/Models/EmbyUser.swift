import Foundation

/// Emby 用户，对应 `UserDto`。
///
/// 字段来源（已核实）：<https://dev.emby.media/reference/RestAPI/UserService/postUsersAuthenticatebyname.html>
/// —— `Name`、`ServerId`、`ServerName`、`Id`、`PrimaryImageTag`、`HasPassword`、
/// `LastLoginDate`、`LastActivityDate`、`DateCreated`、`Policy`、`Configuration`。
///
/// 注意 `IsAdministrator` **不在顶层**，而在嵌套的 `Policy` 对象里
/// （<https://dev.emby.media/reference/pluginapi/MediaBrowser.Model.Users.UserPolicy.html>），
/// 因此 `init(from:)` 需要下钻一层；`Policy` 缺失时按非管理员处理。
public struct EmbyUser: Sendable, Codable, Hashable, Identifiable {
    /// 用户 id（Emby 的 guid 字符串，不是 `UUID` 类型）。
    public let id: String
    /// 用户名。
    public let name: String
    /// 所属服务器 id。
    public let serverId: String
    /// 是否为管理员（来自 `Policy.IsAdministrator`）。
    public let isAdministrator: Bool
    /// 头像 tag。
    public let primaryImageTag: String?

    // MARK: - 契约之外、实际存在的字段

    /// 服务器名（`ServerName`）。
    public let serverName: String?
    /// 是否设置了密码。
    public let hasPassword: Bool
    /// 上次登录时间。
    public let lastLoginDate: Date?
    /// 上次活动时间。
    public let lastActivityDate: Date?
    /// 账号创建时间（Emby 可能返回 `0001-01-01T00:00:00Z` 这种 .NET 零值）。
    public let dateCreated: Date?

    /// 完整初始化。
    public init(
        id: String,
        name: String,
        serverId: String,
        isAdministrator: Bool = false,
        primaryImageTag: String? = nil,
        serverName: String? = nil,
        hasPassword: Bool = false,
        lastLoginDate: Date? = nil,
        lastActivityDate: Date? = nil,
        dateCreated: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.serverId = serverId
        self.isAdministrator = isAdministrator
        self.primaryImageTag = primaryImageTag
        self.serverName = serverName
        self.hasPassword = hasPassword
        self.lastLoginDate = lastLoginDate
        self.lastActivityDate = lastActivityDate
        self.dateCreated = dateCreated
    }

    /// 是否有头像。
    public var hasImage: Bool {
        primaryImageTag?.isEmpty == false
    }

    /// 头像首字母（没有头像时用字母占位符显示）。
    public var initial: String {
        String(name.prefix(1)).uppercased()
    }

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case serverId = "ServerId"
        case primaryImageTag = "PrimaryImageTag"
        case serverName = "ServerName"
        case hasPassword = "HasPassword"
        case lastLoginDate = "LastLoginDate"
        case lastActivityDate = "LastActivityDate"
        case dateCreated = "DateCreated"
        case policy = "Policy"
    }

    /// `Policy` 里我们关心的字段。
    private enum PolicyKeys: String, CodingKey {
        case isAdministrator = "IsAdministrator"
        case isDisabled = "IsDisabled"
        case isHidden = "IsHidden"
    }

    /// 宽松解码：`Policy` 缺失或结构异常时按非管理员处理。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.id = container.decodeFlexibleString(forKey: .id) ?? ""
        self.name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? ""
        self.serverId = container.decodeFlexibleString(forKey: .serverId) ?? ""
        self.primaryImageTag = try? container.decodeIfPresent(String.self, forKey: .primaryImageTag)
        self.serverName = try? container.decodeIfPresent(String.self, forKey: .serverName)
        self.hasPassword = container.decodeFlexibleBool(forKey: .hasPassword) ?? false
        self.lastLoginDate = container.decodeEmbyDateIfPresent(forKey: .lastLoginDate)
        self.lastActivityDate = container.decodeEmbyDateIfPresent(forKey: .lastActivityDate)
        self.dateCreated = container.decodeEmbyDateIfPresent(forKey: .dateCreated)

        // IsAdministrator 藏在 Policy 里；Policy 也可能是 null / 缺失 / 类型异常。
        var administrator = false
        if let policy = try? container.nestedContainer(keyedBy: PolicyKeys.self, forKey: .policy) {
            administrator = (try? policy.decodeIfPresent(Bool.self, forKey: .isAdministrator)) ?? false
        }
        self.isAdministrator = administrator
    }

    /// 按 Emby 的 PascalCase 字段名编码（`IsAdministrator` 仍写回 `Policy`）。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(serverId, forKey: .serverId)
        try container.encodeIfPresent(primaryImageTag, forKey: .primaryImageTag)
        try container.encodeIfPresent(serverName, forKey: .serverName)
        try container.encode(hasPassword, forKey: .hasPassword)
        try container.encodeEmbyDateIfPresent(lastLoginDate, forKey: .lastLoginDate)
        try container.encodeEmbyDateIfPresent(lastActivityDate, forKey: .lastActivityDate)
        try container.encodeEmbyDateIfPresent(dateCreated, forKey: .dateCreated)

        var policy = container.nestedContainer(keyedBy: PolicyKeys.self, forKey: .policy)
        try policy.encode(isAdministrator, forKey: .isAdministrator)
    }
}
