import Foundation

/// Emby 局域网发现协议（UDP 7359）的报文编解码。
///
/// ## 协议事实（✅ 已核实）
///
/// - 服务端在 UDP **7359** 上监听，客户端发送**广播**报文；
/// - 请求正文**逐字**为 `who is EmbyServer?`（区分大小写、含问号、**无换行**）；
/// - 响应是一个 JSON 对象，官方文档写明含三个属性：`Address`、`Id`、`Name`。
///
/// 来源：<https://dev.emby.media/doc/restapi/Locating-the-Server.html>
/// 镜像：<https://github.com/MediaBrowser/Emby/wiki/Locating-the-Server>
///
/// ## 实现差异（社区实测，◐ 多方一致）
///
/// - 真实回包里 `Address` 是**带 scheme 与端口的完整 URL**
///   （`http://192.168.1.51:8096`），而不只是主机名。实测日志：
///   <https://emby.media/community/topic/60163-cannot-get-live-tv-with-emby-theater>
///   —— `Server discovery json: {"Address":"http://192.168.1.51:8096","Id":"f35b…","Name":"EMBY"}`。
/// - 客户端库在解析后还会**额外**带一个 `EndpointAddress`（发送方 IP，无端口），
///   见 Jellyfin 客户端实现
///   <https://github.com/jellyfin/jellyfin-apiclient-python/blob/master/jellyfin_apiclient_python/discovery.py>。
///   这是**客户端侧**补的字段，服务端回包里通常没有；这里作为兜底解析。
/// - 服务端生成响应的源码（Jellyfin 分叉，字段名与 Emby 一致）：
///   <https://github.com/jellyfin/jellyfin/blob/master/Emby.Server.Implementations/Udp/UdpServer.cs>
///   —— `new ServerDiscoveryInfo { Address = localUrl, Id = SystemId, Name = FriendlyName }`。
///   注意 `Address` 取的是服务端自己算出的 `GetLocalApiUrl()`，**可能就是 `http://<ip>:8096`**。
///
/// ## 容错原则
///
/// 发现是「尽力而为」的能力：任何一条回包解析失败都只丢弃这一条，绝不抛错。
/// 字段缺失、大小写不同、`Id` 是数字、`Address` 带或不带端口/路径，都必须能处理。
public enum DiscoveryPacket {
    /// 发现协议使用的 UDP 端口。
    ///
    /// ✅ <https://dev.emby.media/doc/restapi/Locating-the-Server.html>
    public static let defaultPort = 7359

    /// 请求报文的正文（逐字，含问号，无换行）。
    ///
    /// ✅ <https://dev.emby.media/doc/restapi/Locating-the-Server.html>
    /// ⚠️ Jellyfin 用的是 `Who is JellyfinServer?`，**不通用**：Emby 不会回应
    /// Jellyfin 的报文，反之亦然。本项目只发现 Emby，故只发这一种。
    public static let requestText = "who is EmbyServer?"

    /// 请求报文的字节形式（UTF-8，无 BOM，无换行）。
    public static var requestData: Data { Data(requestText.utf8) }

    /// 一条发现回包解析后的原始字段。
    ///
    /// 所有字段都是可选的：真实网络里什么都可能收到，包括完全不相干的 JSON。
    public struct Reply: Sendable, Hashable {
        /// 服务端自报的地址，可能是 `http://host:port`、`host:port` 或裸主机名。
        public let address: String?
        /// 服务器 id（Emby 的 `SystemId`）。
        public let serverId: String?
        /// 服务器展示名。
        public let name: String?
        /// 发送方 IP（无端口）。仅当回包里带 `EndpointAddress` 时存在。
        public let endpointAddress: String?

        /// 完整初始化。
        public init(address: String? = nil, serverId: String? = nil, name: String? = nil, endpointAddress: String? = nil) {
            self.address = address
            self.serverId = serverId
            self.name = name
            self.endpointAddress = endpointAddress
        }

        /// 回包里是否至少有一样可用于连接的信息。
        public var hasUsableAddress: Bool {
            [address, endpointAddress].contains { $0?.isEmpty == false }
        }

        /// 解析成可连接的服务器。
        ///
        /// 地址优先级：`Address` → `EndpointAddress` → 收到回包的源 IP（`sourceHost`）。
        /// 后两者只在服务端没给 `Address`（或给的地址无法解析）时才用得上，
        /// 端口按 ``ServerAddressValidator`` 的默认策略补 `8096`。
        ///
        /// - Parameter sourceHost: 收到该回包的源 IP；传输层拿不到时传 `nil`。
        /// - Returns: 解析出的服务器；无任何可用地址时为 `nil`。
        public func server(receivedFrom sourceHost: String?) -> DiscoveredServer? {
            for candidate in [address, endpointAddress, sourceHost].compactMap({ $0 }) {
                guard let parsed = ServerAddressValidator.parse(candidate) else { continue }
                return DiscoveredServer(
                    address: parsed.host,
                    port: parsed.port,
                    name: name,
                    baseURL: parsed.url
                )
            }
            return nil
        }
    }

    /// 解析一条发现回包。
    ///
    /// 容错：非法 JSON、非对象 JSON（数组/字符串）、空数据、带尾随 `\0` 或换行，
    /// 全部返回 `nil` 而不抛错；字段缺失只让对应属性为 `nil`。
    /// 字段名大小写不敏感（`Address` / `address` 都接受），数值型 `Id` 会转成字符串。
    ///
    /// - Parameter data: UDP 收到的原始字节。
    /// - Returns: 解析结果；不是「看起来像发现回包」的 JSON 时为 `nil`。
    public static func decode(_ data: Data) -> Reply? {
        // 有些实现会在 JSON 后面补 `\0` 或换行，先裁掉首尾空白与控制字符。
        let trimmed = Data(data.drop(while: { $0 == 0x00 || $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }))
        guard !trimmed.isEmpty else { return nil }
        guard let object = (try? JSONSerialization.jsonObject(with: trimmed)) as? [String: Any] else { return nil }

        let reply = Reply(
            address: string(in: object, keys: ["Address"]),
            serverId: string(in: object, keys: ["Id"]),
            name: string(in: object, keys: ["Name"]),
            endpointAddress: string(in: object, keys: ["EndpointAddress"])
        )
        // 三个字段一个都没有 → 不是发现回包（例如误收到的其他 UDP 广播）。
        guard reply.address != nil || reply.serverId != nil || reply.name != nil || reply.endpointAddress != nil else {
            return nil
        }
        return reply
    }

    /// 解析并直接产出可连接的服务器（``Reply/server(receivedFrom:)`` 的便捷入口）。
    ///
    /// - Parameters:
    ///   - data: UDP 收到的原始字节。
    ///   - sourceHost: 发送方 IP；拿不到时传 `nil`。
    /// - Returns: 解析出的服务器；无法解析时为 `nil`。
    public static func server(from data: Data, receivedFrom sourceHost: String?) -> DiscoveredServer? {
        decode(data)?.server(receivedFrom: sourceHost)
    }

    // MARK: - 内部

    /// 大小写不敏感地取一个非空字符串字段。
    ///
    /// - Parameters:
    ///   - object: 已解析的 JSON 对象。
    ///   - keys: 候选字段名（按优先级）。
    /// - Returns: 去空白后的非空字符串；缺失或为空时为 `nil`。
    private static func string(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            for (candidate, value) in object where candidate.caseInsensitiveCompare(key) == .orderedSame {
                if let text = value as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                } else if let number = value as? NSNumber {
                    return number.stringValue
                }
            }
        }
        return nil
    }
}
