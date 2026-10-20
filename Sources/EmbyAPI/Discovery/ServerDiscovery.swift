import Foundation
import PrismCore

/// 服务器发现与地址校验。
///
/// 契约见 `docs/ARCHITECTURE.md` §2.3（冻结）。两条路径：
///
/// 1. ``discover(timeout:)`` —— UDP 广播（端口 7359，报文 `who is EmbyServer?`），
///    收集超时窗口内的所有响应，去重后逐条产出；
/// 2. ``validate(urlString:)`` —— 手动填地址，归一化后请求 `/System/Info/Public` 校验。
///
/// ## 设计要点
///
/// - **网络收发可替换**：全部走 ``DiscoveryTransport``，生产环境是
///   ``BSDDiscoveryTransport``，测试注入脚本化假实现，业务逻辑里没有任何 socket 细节。
/// - **不抛错的发现**：socket 建不起来、发不出去、报文解析失败，都等价于「没找到」，
///   流正常结束。UI 拿到的永远是「可能为空的结果集」，而不是需要处理的异常。
/// - **结构化并发**：`AsyncStream` 的生产任务绑定流的生命周期（`onTermination` 取消），
///   没有 `Task.detached`，也没有裸 `Timer`。
/// - **去重**：同一台服务器可能从多块网卡各回一次，按回包里的服务器 `Id` 去重
///   （`Id` 缺失时退回 `"地址:端口"`），只产出第一次见到的那条。
/// - **顺序稳定**：按响应到达顺序产出，不做二次排序，测试可逐条断言。
public actor ServerDiscovery {
    /// 发现协议使用的 UDP 端口（默认 7359）。
    public let port: Int

    /// 未显式传 `timeout` 时使用的收集窗口。
    public let timeout: Duration

    /// 实际的报文收发通道；为 `nil` 时 ``discover(timeout:)`` 直接返回空流。
    private let transport: (any DiscoveryTransport)?

    /// `/System/Info/Public` 校验器。
    private let probe: ServerProbe

    /// 创建发现器（生产配置）。
    ///
    /// - Parameters:
    ///   - port: UDP 端口，Emby 固定为 7359。
    ///   - timeout: 默认收集窗口，3 秒。
    public init(port: Int = DiscoveryPacket.defaultPort, timeout: Duration = .seconds(3)) {
        self.port = port
        self.timeout = timeout
        self.transport = BSDDiscoveryTransport()
        self.probe = ServerProbe()
    }

    /// 测试注入用初始化。
    ///
    /// - Parameters:
    ///   - port: UDP 端口。
    ///   - timeout: 默认收集窗口。
    ///   - transport: 报文收发通道；`nil` 表示「不可发现」，`discover` 直接返回空流。
    ///   - probe: 地址校验器。
    init(
        port: Int = DiscoveryPacket.defaultPort,
        timeout: Duration = .seconds(3),
        transport: (any DiscoveryTransport)?,
        probe: ServerProbe = ServerProbe()
    ) {
        self.port = port
        self.timeout = timeout
        self.transport = transport
        self.probe = probe
    }

    // MARK: - 自动发现

    /// 发送 UDP 广播并收集响应，超时后正常结束流。
    ///
    /// 产出顺序 = 响应到达顺序；同一服务器只产出一次。超时、socket 失败、
    /// 报文非法都**不会**抛错，流只是结束。
    ///
    /// 用法：
    /// ```swift
    /// for await server in discovery.discover() {
    ///     print(server.name, server.baseURL)
    /// }
    /// ```
    ///
    /// - Parameter timeout: 收集窗口；`nil` 表示使用初始化时的默认值（3 秒）。
    /// - Returns: 服务器流。消费者取消任务或跳出循环时，内部任务会被取消并释放 socket。
    public func discover(timeout: Duration? = nil) -> AsyncStream<DiscoveredServer> {
        let effectiveTimeout = timeout ?? self.timeout
        let port = self.port
        guard let transport else {
            return AsyncStream { $0.finish() }
        }

        return AsyncStream { continuation in
            let task = Task {
                await Self.run(
                    transport: transport,
                    port: port,
                    timeout: effectiveTimeout,
                    emit: continuation
                )
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// ``discover(timeout:)`` 的数组版本（`await` 一次拿全部结果）。
    ///
    /// 适合「打开发现页时展示一次列表」这类不需要逐条渲染的场景。
    ///
    /// - Parameter timeout: 收集窗口；`nil` 表示使用初始化时的默认值。
    /// - Returns: 去重后的服务器列表（响应到达顺序）。
    public func discoverAll(timeout: Duration? = nil) async -> [DiscoveredServer] {
        var servers: [DiscoveredServer] = []
        for await server in discover(timeout: timeout) {
            servers.append(server)
        }
        return servers
    }

    // MARK: - 手动地址校验

    /// 校验手动输入的服务器地址。
    ///
    /// 流程：归一化（补 scheme / 端口，见 ``ServerAddressValidator``）→
    /// `GET {base}/System/Info/Public` → 成功则返回连接记录与公开信息。
    ///
    /// - Parameter urlString: 用户原始输入，可含空格/换行/全角字符。
    /// - Returns: 已校验的连接记录（`id` 为服务器 id）与公开信息。
    /// - Throws:
    ///   - ``PrismCore/EmbyError/invalidURL``：输入无法解析成合法 http(s) 地址（不发请求）。
    ///   - ``PrismCore/EmbyError/timeout``：请求超时。
    ///   - ``PrismCore/EmbyError/serverUnreachable(_:)``：连不上 / DNS 失败 / 证书失败。
    ///   - ``PrismCore/EmbyError/decoding(_:)``：返回体不是预期 JSON（例如打到了非 Emby 服务）。
    ///   - ``PrismCore/EmbyError/unauthorized`` / ``forbidden`` / ``notFound`` / ``server(status:message:)``：
    ///     服务端返回对应状态码。
    public func validate(urlString: String) async throws -> (ServerConnection, PublicServerInfo) {
        let baseURL = try ServerAddressValidator.normalize(urlString)
        let info = try await probe.fetchPublicInfo(baseURL: baseURL)
        var connection = ServerConnection(info: info, baseURL: baseURL)
        connection.lastConnectedAt = Date()
        return (connection, info)
    }

    // MARK: - 内部流程

    /// 发现主循环：建通道 → 发广播 → 收到期为止 → 关通道 → 结束流。
    ///
    /// `nonisolated`：整个流程只用参数与局部状态，不碰 actor 的隔离状态，
    /// 这样流的消费者不会被 actor 串行化卡住。
    ///
    /// - Parameters:
    ///   - transport: 报文收发通道。
    ///   - port: UDP 端口。
    ///   - timeout: 收集窗口。
    ///   - emit: 结果流的 continuation。
    private nonisolated static func run(
        transport: any DiscoveryTransport,
        port: Int,
        timeout: Duration,
        emit: AsyncStream<DiscoveredServer>.Continuation
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var seen = Set<String>()

        do {
            try await transport.start(port: port)
            try await transport.send(DiscoveryPacket.requestData)

            while clock.now < deadline, !Task.isCancelled {
                guard let datagram = await transport.receive(until: deadline) else { break }
                guard let reply = DiscoveryPacket.decode(datagram.data),
                      let server = reply.server(receivedFrom: datagram.sourceHost)
                else { continue }

                // 优先按服务器 Id 去重；Id 缺失时退回契约里的 "地址:端口"。
                guard seen.insert(reply.serverId ?? server.id).inserted else { continue }
                emit.yield(server)
            }
        } catch {
            // 发现是「尽力而为」的能力：socket 建不起来 / 发不出去都等价于「没找到」。
        }

        await transport.cancel()
        emit.finish()
    }
}
