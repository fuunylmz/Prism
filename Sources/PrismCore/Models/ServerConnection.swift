import Foundation

/// 一个已保存的服务器连接。
///
/// 契约未给出字段，这里按 `ServerDiscovery` / `EmbyClient` 的需要定义：
/// `EmbyClient.init(server:identity:session:)` 需要一个能拼出 `baseURL` 的值对象，
/// 而会话恢复需要一个稳定可持久化的 `id`。
///
/// `id` 用服务器 id（`PublicServerInfo.id`）而不是地址，因为同一个服务器可能
/// 同时有局域网地址和公网地址，切换地址不应产生两条记录。
public struct ServerConnection: Sendable, Codable, Hashable, Identifiable {
    /// 服务器 id（来自 `/System/Info/Public` 的 `Id`）。
    public let id: String
    /// 展示名（优先用户自定义名，其次服务器名）。
    public var name: String
    /// 服务器基地址，例如 `http://192.168.1.10:8096`。
    public var baseURL: URL
    /// 是否为演示模式服务器（Demo Mode，不产生真实网络请求）。
    public var isDemo: Bool
    /// 上次成功连接的绝对时间。
    public var lastConnectedAt: Date?

    /// 完整初始化。
    ///
    /// - Parameters:
    ///   - id: 服务器 id。
    ///   - name: 展示名。
    ///   - baseURL: 服务器基地址（需含 scheme 与端口）。
    ///   - isDemo: 是否为演示服务器。
    ///   - lastConnectedAt: 上次成功连接时间。
    public init(
        id: String,
        name: String,
        baseURL: URL,
        isDemo: Bool = false,
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.isDemo = isDemo
        self.lastConnectedAt = lastConnectedAt
    }

    /// 从公开信息 + 地址构造连接记录。
    ///
    /// - Parameters:
    ///   - info: `/System/Info/Public` 的返回。
    ///   - baseURL: 实际可用的基地址。
    /// - Returns: 新的连接记录。
    public init(info: PublicServerInfo, baseURL: URL) {
        self.init(
            id: info.id,
            name: info.serverName.isEmpty ? (baseURL.host() ?? baseURL.absoluteString) : info.serverName,
            baseURL: baseURL
        )
    }

    /// 是否为 `https` 连接。
    public var isSecure: Bool {
        baseURL.scheme?.lowercased() == "https"
    }

    /// 主机名（不含端口）。
    public var host: String {
        baseURL.host() ?? ""
    }

    /// 端口；未显式指定时按 scheme 推断（80 / 443）。
    public var port: Int? {
        if let port = baseURL.port { return port }
        switch baseURL.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case baseURL
        case isDemo
        case lastConnectedAt
    }

    /// 宽松解码：`baseURL` 缺失或非法时退化为 `about:blank`，保证历史数据不会让启动崩溃。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? ""
        self.name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? ""
        let url = try? container.decodeIfPresent(URL.self, forKey: .baseURL)
        self.baseURL = url ?? URL(string: "about:blank") ?? URL(filePath: "/")
        self.isDemo = (try? container.decodeIfPresent(Bool.self, forKey: .isDemo)) ?? false
        self.lastConnectedAt = try? container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
    }

    /// 编码为持久化用的 JSON。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(isDemo, forKey: .isDemo)
        try container.encodeEmbyDateIfPresent(lastConnectedAt, forKey: .lastConnectedAt)
    }
}
