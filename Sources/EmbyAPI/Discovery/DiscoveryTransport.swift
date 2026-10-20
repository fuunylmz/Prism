import Foundation

/// 收到的一条发现回包。
///
/// 除原始字节外还带上发送方 IP：服务端偶尔会漏掉 `Address` 字段，
/// 此时用「谁回的我」作为兜底地址（与 Jellyfin 客户端补 `EndpointAddress` 的思路一致）。
public struct DiscoveryDatagram: Sendable, Hashable {
    /// UDP 报文的原始字节。
    public let data: Data
    /// 发送方 IP（不带端口）；传输层无法获知时为 `nil`。
    public let sourceHost: String?

    /// 完整初始化。
    ///
    /// - Parameters:
    ///   - data: UDP 报文的原始字节。
    ///   - sourceHost: 发送方 IP。
    public init(data: Data, sourceHost: String? = nil) {
        self.data = data
        self.sourceHost = sourceHost
    }
}

/// UDP 发现报文的收发抽象。
///
/// 存在的意义是**把网络收发从发现逻辑里剥离**：``ServerDiscovery`` 只依赖这个协议，
/// 生产环境注入 ``BSDDiscoveryTransport``（BSD socket 广播），测试注入脚本化的假实现，
/// 从而做到「发现流程可单测、测试不碰真实网络」。
///
/// ## 实现约定
///
/// - ``start(port:)`` 负责建 socket 并绑定**随机本地端口**（不要绑 7359——那是服务端的监听端口）。
/// - ``send(_:)`` 把报文发到广播地址；失败应抛错。
/// - ``receive(until:)`` 阻塞到收到一条报文或**到达 deadline**；到达 deadline 必须返回 `nil`
///   而不是抛错或永远挂起，``ServerDiscovery`` 依赖这个语义结束流。
/// - ``cancel()`` 释放资源，必须可重复调用。
public protocol DiscoveryTransport: Sendable {
    /// 准备传输通道（建 socket / 绑定端口）。
    ///
    /// - Parameter port: 目标 UDP 端口（Emby 为 7359）。
    /// - Throws: socket 无法创建或绑定时抛出。
    func start(port: Int) async throws

    /// 发送一条广播报文。
    ///
    /// - Parameter data: 报文正文。
    /// - Throws: 发送失败时抛出。
    func send(_ data: Data) async throws

    /// 等待下一条回包。
    ///
    /// - Parameter deadline: 本次发现的截止时刻；到达后必须返回 `nil`。
    /// - Returns: 收到的报文；超时、通道结束或已取消时为 `nil`。
    func receive(until deadline: ContinuousClock.Instant) async -> DiscoveryDatagram?

    /// 释放资源（关闭 socket）。可重复调用。
    func cancel() async
}
