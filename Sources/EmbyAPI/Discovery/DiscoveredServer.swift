import Foundation

/// 局域网自动发现到的一台 Emby 服务器。
///
/// 契约见 `docs/ARCHITECTURE.md` §2.3（冻结）：
/// `id` 固定为 `"\(address):\(port)"`，`baseURL` 是可直接用于请求的基地址。
///
/// 注意 `id` 是**地址标识**而不是服务器 id：同一台服务器可能同时从多块网卡
/// 被广播到（地址不同），此时会产生多个 `DiscoveredServer`。
/// 按服务器 id 去重是 ``ServerDiscovery`` 的职责，两者不要混淆。
public struct DiscoveredServer: Sendable, Identifiable, Hashable {
    /// 稳定标识，形如 `192.168.1.10:8096`（契约规定）。
    public let id: String

    /// 服务器展示名。
    ///
    /// 来自发现响应的 `Name` 字段；该字段缺失或为空时退化为 `"地址:端口"`，
    /// 保证 UI 永远有东西可显示。
    public let name: String

    /// 主机部分（不含 scheme 与端口），例如 `192.168.1.10`。
    public let address: String

    /// 服务端口，例如 `8096`。
    public let port: Int

    /// 可直接用于请求的基地址，例如 `http://192.168.1.10:8096`。
    public var baseURL: URL

    /// 完整初始化。
    ///
    /// - Parameters:
    ///   - id: 稳定标识，调用方负责按契约拼成 `"\(address):\(port)"`。
    ///   - name: 展示名。
    ///   - address: 主机部分（不含 scheme 与端口）。
    ///   - port: 服务端口。
    ///   - baseURL: 可直接用于请求的基地址。
    public init(id: String, name: String, address: String, port: Int, baseURL: URL) {
        self.id = id
        self.name = name
        self.address = address
        self.port = port
        self.baseURL = baseURL
    }

    /// 由地址与端口构造，`id` 按契约自动生成为 `"\(address):\(port)"`。
    ///
    /// - Parameters:
    ///   - address: 主机部分（不含 scheme 与端口）。
    ///   - port: 服务端口。
    ///   - name: 展示名；传 `nil` 时退化为 `"\(address):\(port)"`。
    ///   - baseURL: 基地址；传 `nil` 时按 `http://address:port` 拼装。
    public init(address: String, port: Int, name: String? = nil, baseURL: URL? = nil) {
        let identifier = "\(address):\(port)"
        self.id = identifier
        self.name = (name?.isEmpty == false) ? (name ?? identifier) : identifier
        self.address = address
        self.port = port
        self.baseURL = baseURL ?? URL(string: "http://\(address):\(port)") ?? URL(filePath: "/")
    }

    /// 是否为 `https` 连接。
    public var isSecure: Bool {
        baseURL.scheme?.lowercased() == "https"
    }
}
