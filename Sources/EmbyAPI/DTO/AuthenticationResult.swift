import Foundation
import PrismCore

/// 登录请求体，对应 Emby 的 `AuthenticateUserByName`。
///
/// 字段来源（已核实）：<https://dev.emby.media/reference/RestAPI/UserService/postUsersAuthenticatebyname.html>
/// —— `Username: string`、`Pw: string`。
///
/// - Important: 密码字段名是 **`Pw`**，不是 `Password`。写错会被服务器当成空密码，
///   表现为 401 或「用户名或密码错误」，且不会有任何提示。
public struct AuthenticateUserByName: Sendable, Codable, Hashable {
    /// 用户名。
    public let username: String

    /// 明文密码（对应 JSON 的 `Pw`）。
    ///
    /// 官方文档明确要求明文传输，因此**必须走 HTTPS**，否则凭据裸奔。
    public let password: String

    /// 完整初始化。
    ///
    /// - Parameters:
    ///   - username: 用户名。
    ///   - password: 明文密码。
    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    private enum CodingKeys: String, CodingKey {
        case username = "Username"
        case password = "Pw"
    }
}

/// 登录响应，对应 Emby 的 `AuthenticationResult`。
///
/// 字段来源（已核实）：<https://dev.emby.media/reference/RestAPI/UserService/postUsersAuthenticatebyname.html>
/// —— `User`、`SessionInfo`、`AccessToken`、`ServerId`。
///
/// ## ⚠️ `User` 是对象还是数组（本项目已核实的关键坑）
///
/// 官方 Swagger 把 `User` 标成 `UserDto[]`（**数组**），`SessionInfo` 标成 `SessionInfo[]`，
/// 但 Emby 实际返回的是**单个对象**（见 `docs/research/verified-facts.md` A4）。
/// 因此 ``init(from:)`` 用 ``OneOrMany`` 同时容忍两种形态（对象、单元素数组、空数组），
/// 两种都能吃，空数组则退化为空用户而**不抛错**。
///
/// - Note: 业务层通常只需要 ``asSession`` 得到的 ``PrismCore/AuthSession``（可持久化），
///   本类型负责保留服务端多给的 `SessionInfo`。
public struct AuthenticationResult: Sendable, Codable, Hashable {
    /// 后续请求要放进 `X-Emby-Token` 的访问令牌。
    public let accessToken: String

    /// 服务器 id（多服务器场景必须与 token 一起存）。
    public let serverId: String

    /// 登录用户。
    public let user: EmbyUser

    /// 本次登录创建的会话；服务器没返回时为 `nil`。
    public let sessionInfo: SessionInfo?

    /// 完整初始化。
    ///
    /// - Parameters:
    ///   - accessToken: 访问令牌。
    ///   - serverId: 服务器 id。
    ///   - user: 登录用户。
    ///   - sessionInfo: 会话信息。
    public init(
        accessToken: String,
        serverId: String,
        user: EmbyUser,
        sessionInfo: SessionInfo? = nil
    ) {
        self.accessToken = accessToken
        self.serverId = serverId
        self.user = user
        self.sessionInfo = sessionInfo
    }

    /// 转换为可持久化的 ``PrismCore/AuthSession``。
    ///
    /// `serverId` / `userId` 缺失时按用户对象里的值兜底（与 ``PrismCore/AuthSession`` 的规则一致）。
    public var asSession: AuthSession {
        AuthSession(
            serverId: serverId.isEmpty ? user.serverId : serverId,
            userId: user.id,
            accessToken: accessToken,
            user: user
        )
    }

    /// 令牌是否可用。
    public var isValid: Bool {
        !accessToken.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken = "AccessToken"
        case serverId = "ServerId"
        case user = "User"
        case sessionInfo = "SessionInfo"
    }

    /// 宽松解码：`User` / `SessionInfo` 同时容忍对象与数组；其余字段缺失时退化为空串。
    ///
    /// - Parameter decoder: 解码器。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let decodedUser: EmbyUser
        if let wrapper = try? container.decodeIfPresent(OneOrMany<EmbyUser>.self, forKey: .user),
           let value = wrapper.value {
            decodedUser = value
        } else {
            decodedUser = EmbyUser(id: "", name: "", serverId: "")
        }
        self.user = decodedUser

        self.accessToken = container.embyString(forKey: .accessToken) ?? ""

        let decodedServerId = container.embyString(forKey: .serverId) ?? ""
        self.serverId = decodedServerId.isEmpty ? decodedUser.serverId : decodedServerId

        let wrapper = try? container.decodeIfPresent(OneOrMany<SessionInfo>.self, forKey: .sessionInfo)
        self.sessionInfo = wrapper?.value
    }

    /// 按 Emby 的 PascalCase 字段名编码（`User` 写回为单个对象）。
    ///
    /// - Parameter encoder: 编码器。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accessToken, forKey: .accessToken)
        try container.encode(serverId, forKey: .serverId)
        try container.encode(user, forKey: .user)
        try container.encodeIfPresent(sessionInfo, forKey: .sessionInfo)
    }
}

/// 会话信息，对应 Emby 的 `SessionInfo`。
///
/// 字段来源（已核实）：<https://dev.emby.media/reference/pluginapi/MediaBrowser.Controller.Session.SessionInfo.html>
/// 与 <https://dev.emby.media/reference/RestAPI/UserService/postUsersAuthenticatebyname.html>
/// 的 Definitions 段（`Id`、`ServerId`、`UserId`、`UserName`、`UserPrimaryImageTag`、`Client`、
/// `DeviceName`、`DeviceType`、`DeviceId`、`ApplicationVersion`、`LastActivityDate`、
/// `RemoteEndPoint`、`Protocol`、`PlayableMediaTypes`、`SupportedCommands`、
/// `SupportsRemoteControl`、`NowPlayingItem`）。
///
/// 本类型只保留客户端会用到的字段；`PlayState` / `TranscodingInfo` 等播放态字段
/// 属于「会话列表 / 远程控制」（P2），不在本 DTO 范围内。
public struct SessionInfo: Sendable, Codable, Hashable, Identifiable {
    /// 会话 id。
    public let id: String
    /// 服务器 id。
    public let serverId: String
    /// 用户 id。
    public let userId: String
    /// 用户名。
    public let userName: String
    /// 用户头像 tag。
    public let userPrimaryImageTag: String?
    /// 客户端名（如 `Prism`）。
    public let client: String?
    /// 设备名。
    public let deviceName: String?
    /// 设备类型。
    public let deviceType: String?
    /// 设备 id（必须与本地持久化的 `DeviceId` 一致）。
    public let deviceId: String?
    /// 客户端版本。
    public let applicationVersion: String?
    /// 上次活动时间。
    public let lastActivityDate: Date?
    /// 对端 IP。
    public let remoteEndPoint: String?
    /// 传输协议（JSON 的 `Protocol`）。
    public let protocolName: String?
    /// 可播放的媒体类型（`Audio` / `Video`…）。
    public let playableMediaTypes: [String]
    /// 服务端支持的命令。
    public let supportedCommands: [String]
    /// 是否支持远程控制。
    public let supportsRemoteControl: Bool
    /// 当前正在播放的条目（没有播放时为 `nil`）。
    public let nowPlayingItem: MediaItem?

    /// 完整初始化。
    ///
    /// - Parameters:
    ///   - id: 会话 id。
    ///   - serverId: 服务器 id。
    ///   - userId: 用户 id。
    ///   - userName: 用户名。
    ///   - userPrimaryImageTag: 用户头像 tag。
    ///   - client: 客户端名。
    ///   - deviceName: 设备名。
    ///   - deviceType: 设备类型。
    ///   - deviceId: 设备 id。
    ///   - applicationVersion: 客户端版本。
    ///   - lastActivityDate: 上次活动时间。
    ///   - remoteEndPoint: 对端 IP。
    ///   - protocolName: 传输协议。
    ///   - playableMediaTypes: 可播放的媒体类型。
    ///   - supportedCommands: 服务端支持的命令。
    ///   - supportsRemoteControl: 是否支持远程控制。
    ///   - nowPlayingItem: 当前播放条目。
    public init(
        id: String,
        serverId: String = "",
        userId: String = "",
        userName: String = "",
        userPrimaryImageTag: String? = nil,
        client: String? = nil,
        deviceName: String? = nil,
        deviceType: String? = nil,
        deviceId: String? = nil,
        applicationVersion: String? = nil,
        lastActivityDate: Date? = nil,
        remoteEndPoint: String? = nil,
        protocolName: String? = nil,
        playableMediaTypes: [String] = [],
        supportedCommands: [String] = [],
        supportsRemoteControl: Bool = false,
        nowPlayingItem: MediaItem? = nil
    ) {
        self.id = id
        self.serverId = serverId
        self.userId = userId
        self.userName = userName
        self.userPrimaryImageTag = userPrimaryImageTag
        self.client = client
        self.deviceName = deviceName
        self.deviceType = deviceType
        self.deviceId = deviceId
        self.applicationVersion = applicationVersion
        self.lastActivityDate = lastActivityDate
        self.remoteEndPoint = remoteEndPoint
        self.protocolName = protocolName
        self.playableMediaTypes = playableMediaTypes
        self.supportedCommands = supportedCommands
        self.supportsRemoteControl = supportsRemoteControl
        self.nowPlayingItem = nowPlayingItem
    }

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case serverId = "ServerId"
        case userId = "UserId"
        case userName = "UserName"
        case userPrimaryImageTag = "UserPrimaryImageTag"
        case client = "Client"
        case deviceName = "DeviceName"
        case deviceType = "DeviceType"
        case deviceId = "DeviceId"
        case applicationVersion = "ApplicationVersion"
        case lastActivityDate = "LastActivityDate"
        case remoteEndPoint = "RemoteEndPoint"
        case protocolName = "Protocol"
        case playableMediaTypes = "PlayableMediaTypes"
        case supportedCommands = "SupportedCommands"
        case supportsRemoteControl = "SupportsRemoteControl"
        case nowPlayingItem = "NowPlayingItem"
    }

    /// 宽松解码：所有字段缺失都退化为空值，`NowPlayingItem` 用 ``PrismCore/MediaItem`` 承接。
    ///
    /// - Parameter decoder: 解码器。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = container.embyString(forKey: .id) ?? ""
        self.serverId = container.embyString(forKey: .serverId) ?? ""
        self.userId = container.embyString(forKey: .userId) ?? ""
        self.userName = container.embyString(forKey: .userName) ?? ""
        self.userPrimaryImageTag = container.embyString(forKey: .userPrimaryImageTag)
        self.client = container.embyString(forKey: .client)
        self.deviceName = container.embyString(forKey: .deviceName)
        self.deviceType = container.embyString(forKey: .deviceType)
        self.deviceId = container.embyString(forKey: .deviceId)
        self.applicationVersion = container.embyString(forKey: .applicationVersion)
        self.lastActivityDate = container.decodeEmbyDateIfPresent(forKey: .lastActivityDate)
        self.remoteEndPoint = container.embyString(forKey: .remoteEndPoint)
        self.protocolName = container.embyString(forKey: .protocolName)
        self.playableMediaTypes = container.decodeStringArrayIfPresent(forKey: .playableMediaTypes)
        self.supportedCommands = container.decodeStringArrayIfPresent(forKey: .supportedCommands)
        self.supportsRemoteControl = container.embyBool(forKey: .supportsRemoteControl) ?? false
        // `NowPlayingItem` 在 Reference 里被标成 `BaseItemDto[]`，实际是对象，用 OneOrMany 兜底。
        let nowPlaying = try? container.decodeIfPresent(OneOrMany<MediaItem>.self, forKey: .nowPlayingItem)
        self.nowPlayingItem = nowPlaying?.value
    }

    /// 按 Emby 的 PascalCase 字段名编码。
    ///
    /// - Parameter encoder: 编码器。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(serverId, forKey: .serverId)
        try container.encode(userId, forKey: .userId)
        try container.encode(userName, forKey: .userName)
        try container.encodeIfPresent(userPrimaryImageTag, forKey: .userPrimaryImageTag)
        try container.encodeIfPresent(client, forKey: .client)
        try container.encodeIfPresent(deviceName, forKey: .deviceName)
        try container.encodeIfPresent(deviceType, forKey: .deviceType)
        try container.encodeIfPresent(deviceId, forKey: .deviceId)
        try container.encodeIfPresent(applicationVersion, forKey: .applicationVersion)
        try container.encodeEmbyDateIfPresent(lastActivityDate, forKey: .lastActivityDate)
        try container.encodeIfPresent(remoteEndPoint, forKey: .remoteEndPoint)
        try container.encodeIfPresent(protocolName, forKey: .protocolName)
        try container.encode(playableMediaTypes, forKey: .playableMediaTypes)
        try container.encode(supportedCommands, forKey: .supportedCommands)
        try container.encode(supportsRemoteControl, forKey: .supportsRemoteControl)
        try container.encodeIfPresent(nowPlayingItem, forKey: .nowPlayingItem)
    }
}
