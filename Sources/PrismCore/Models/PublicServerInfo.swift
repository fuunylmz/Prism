import Foundation

/// 服务器公开信息，对应 `GET /System/Info/Public` 的 `PublicSystemInfo`。
///
/// 字段来源（已核实）：<https://dev.emby.media/reference/RestAPI/SystemService/getSystemInfoPublic.html>
/// —— `Id`、`ServerName`、`Version`、`LocalAddress`、`WanAddress`、`LocalAddresses`、`RemoteAddresses`。
///
/// 该接口**不需要鉴权**，是连接校验（“这个地址真的是 Emby 吗”）的第一站。
public struct PublicServerInfo: Sendable, Codable, Hashable, Identifiable {
    /// 服务器 id。
    public let id: String
    /// 服务器名（用户可自定义，如 “My Emby”）。
    public let serverName: String
    /// 服务器版本号（如 `4.8.11.0`）。
    public let version: String
    /// 局域网地址。
    public let localAddress: String?
    /// 公网地址。
    public let wanAddress: String?
    /// 全部局域网地址。
    public let localAddresses: [String]
    /// 全部远程地址。
    public let remoteAddresses: [String]

    /// 完整初始化。
    public init(
        id: String,
        serverName: String,
        version: String,
        localAddress: String? = nil,
        wanAddress: String? = nil,
        localAddresses: [String] = [],
        remoteAddresses: [String] = []
    ) {
        self.id = id
        self.serverName = serverName
        self.version = version
        self.localAddress = localAddress
        self.wanAddress = wanAddress
        self.localAddresses = localAddresses
        self.remoteAddresses = remoteAddresses
    }

    /// 主版本号（`4.8.11.0` → `4`）；无法解析时为 `nil`。
    public var majorVersion: Int? {
        Int(version.split(separator: ".").first ?? "")
    }

    /// 是否为 Jellyfin 服务器（Emby 的兼容分支，行为有细微差异）。
    ///
    /// 公开信息里没有显式的产品标识，只能靠版本号命名约定做启发式判断；
    /// 判断不出来时按 Emby 处理（本项目的主目标）。
    public var isLikelyJellyfin: Bool {
        version.lowercased().contains("jellyfin")
    }

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case serverName = "ServerName"
        case version = "Version"
        case localAddress = "LocalAddress"
        case wanAddress = "WanAddress"
        case localAddresses = "LocalAddresses"
        case remoteAddresses = "RemoteAddresses"
    }

    /// 宽松解码：`Id` / `ServerName` / `Version` 缺失时退化为空串。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = container.decodeFlexibleString(forKey: .id) ?? ""
        self.serverName = (try? container.decodeIfPresent(String.self, forKey: .serverName)) ?? ""
        self.version = (try? container.decodeIfPresent(String.self, forKey: .version)) ?? ""
        self.localAddress = try? container.decodeIfPresent(String.self, forKey: .localAddress)
        self.wanAddress = try? container.decodeIfPresent(String.self, forKey: .wanAddress)
        self.localAddresses = container.decodeStringArrayIfPresent(forKey: .localAddresses)
        self.remoteAddresses = container.decodeStringArrayIfPresent(forKey: .remoteAddresses)
    }

    /// 按 Emby 的 PascalCase 字段名编码。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(serverName, forKey: .serverName)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(localAddress, forKey: .localAddress)
        try container.encodeIfPresent(wanAddress, forKey: .wanAddress)
        try container.encode(localAddresses, forKey: .localAddresses)
        try container.encode(remoteAddresses, forKey: .remoteAddresses)
    }
}
