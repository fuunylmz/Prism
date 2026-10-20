import Foundation

/// 一次成功登录的会话。
///
/// 直接对应登录端点 `POST /Users/AuthenticateByName` 返回的 `AuthenticationResult`
/// （字段来源已核实：<https://dev.emby.media/reference/RestAPI/UserService/postUsersAuthenticatebyname.html>）：
/// `User`、`SessionInfo`、`AccessToken`、`ServerId`。
///
/// **兼容性处理（重要）**
/// 官方 Swagger 把 `AuthenticationResult.User` 标注成 `UserDto[]`（数组），
/// 但 Emby 实际返回的是**单个对象**（见 `docs/research/verified-facts.md` A4）。
/// 因此 `init(from:)` 同时容忍两种形态：对象、单元素数组（甚至空数组）。
public struct AuthSession: Sendable, Codable, Hashable, Identifiable {
    /// 所属服务器 id。
    public let serverId: String
    /// 用户 id。
    public let userId: String
    /// 后续请求要放进 `X-Emby-Token` 的访问令牌。
    public let accessToken: String
    /// 登录用户。
    public let user: EmbyUser
    /// 会话创建时间（本地记录，服务端不返回）。
    public let createdAt: Date?

    /// `Identifiable` 要求；同一服务器同一用户视为同一会话。
    public var id: String {
        "\(serverId):\(userId)"
    }

    /// 完整初始化。
    public init(
        serverId: String,
        userId: String,
        accessToken: String,
        user: EmbyUser,
        createdAt: Date? = nil
    ) {
        self.serverId = serverId
        self.userId = userId
        self.accessToken = accessToken
        self.user = user
        self.createdAt = createdAt
    }

    /// 以用户对象构造（`serverId` / `userId` 从用户里取）。
    ///
    /// - Parameters:
    ///   - accessToken: 访问令牌。
    ///   - user: 登录用户。
    ///   - createdAt: 创建时间。
    public init(accessToken: String, user: EmbyUser, createdAt: Date? = nil) {
        self.init(
            serverId: user.serverId,
            userId: user.id,
            accessToken: accessToken,
            user: user,
            createdAt: createdAt
        )
    }

    /// 是否携带了可用的令牌。
    public var isValid: Bool {
        !accessToken.isEmpty && !userId.isEmpty
    }

    /// 用于日志的脱敏描述：令牌只保留长度，绝不输出令牌内容本身。
    public var redactedDescription: String {
        let tokenPart = accessToken.isEmpty ? "none" : "\(accessToken.count) chars"
        return "AuthSession(server: \(serverId), user: \(user.name), token: \(tokenPart))"
    }

    private enum CodingKeys: String, CodingKey {
        case serverId = "ServerId"
        case userId = "UserId"
        case accessToken = "AccessToken"
        case user = "User"
        case createdAt = "CreatedAt"
    }

    /// 宽松解码：`User` 兼容对象与数组两种形态，`ServerId` / `UserId` 缺失时从 `User` 推导。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let user = Self.decodeUser(from: container) ?? EmbyUser(id: "", name: "", serverId: "")
        self.user = user
        self.accessToken = container.decodeFlexibleString(forKey: .accessToken) ?? ""

        let serverId = container.decodeFlexibleString(forKey: .serverId) ?? ""
        self.serverId = serverId.isEmpty ? user.serverId : serverId

        let userId = container.decodeFlexibleString(forKey: .userId) ?? ""
        self.userId = userId.isEmpty ? user.id : userId

        // 与 `encode(to:)` 严格对称：编码走 `encodeEmbyDateIfPresent`（ISO8601 字符串），
        // 解码必须用 `decodeEmbyDateIfPresent`。
        // 用裸 `try? decodeIfPresent(Date.self, ...)` 会在默认解码策略下期望 Double 秒数，
        // 遇到 ISO8601 字符串时**静默返回 nil**（`try?` 吞掉了类型不匹配错误），
        // 曾导致 `ServerRegistry` 的「最近使用」排序全部失效。这是真实发生过的 bug。
        self.createdAt = container.decodeEmbyDateIfPresent(forKey: .createdAt)
    }

    /// 按 `AuthenticationResult` 的 PascalCase 字段名编码。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(serverId, forKey: .serverId)
        try container.encode(userId, forKey: .userId)
        try container.encode(accessToken, forKey: .accessToken)
        try container.encode(user, forKey: .user)
        try container.encodeEmbyDateIfPresent(createdAt, forKey: .createdAt)
    }

    /// 兼容解码 `User`：先按对象解，失败再按数组取第一个元素。
    ///
    /// - Parameter container: 解码容器。
    /// - Returns: 用户对象；两种形态都失败时为 `nil`。
    private static func decodeUser(from container: KeyedDecodingContainer<CodingKeys>) -> EmbyUser? {
        if let user = try? container.decodeIfPresent(EmbyUser.self, forKey: .user) {
            return user
        }
        if let users = try? container.decodeIfPresent([EmbyUser].self, forKey: .user) {
            return users.first
        }
        return nil
    }
}
