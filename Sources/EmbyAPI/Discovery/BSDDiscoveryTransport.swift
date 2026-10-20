import Darwin
import Foundation
import PrismCore

/// 基于 BSD socket 的真实 UDP 广播实现。
///
/// ## 为什么不用 `NWConnection`
///
/// 工单原建议用 `Network.framework` 的 `NWConnection`，但 Apple 官方技术说明
/// TN3151 明确写着：**Network framework 不支持 UDP 广播**
/// （"Network framework supports UDP multicast using the NWConnectionGroup class,
/// but that support has limits and, specifically, it does not support UDP broadcast.
/// If you need something that's not supported by Network framework, use BSD Sockets."）。
///
/// 来源：<https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api>
/// 旁证（DTS 工程师回复：Networking 库不是为接收广播设计的，社区最终退回 BSD socket）：
/// <https://stackoverflow.com/questions/62622612/nwnetworking-nwlistener-how-to-correctly-receive-udp-broadcast-messages>
///
/// 因此这里用 BSD socket：
/// - 打开 IPv4 + IPv6 两个 socket，绑定**随机本地端口**（0，不是 7359）；
/// - 设 `SO_BROADCAST`（macOS 上不发这个选项，广播报文会被内核直接拒绝）；
/// - 发送目标为 `255.255.255.255:7359`，并按网卡算出的**子网定向广播**（如
///   `192.168.1.255`）各发一份——命中率更高，见 `docs/research/emby-api.md` §3.1；
/// - 用 `poll(2)` 分片等待，既能及时响应取消，也能在 deadline 到达时干净返回。
///
/// ## 沙盒注意
///
/// App 开启 App Sandbox 时需要 `com.apple.security.network.client`（发广播）与
/// `com.apple.security.network.server`（收回包）；macOS 15+ 首次广播可能触发
/// 「本地网络」隐私弹窗（需要 `NSLocalNetworkUsageDescription`）。
/// 这些属于 App target 的配置，不在本模块范围内。
public actor BSDDiscoveryTransport: DiscoveryTransport {
    /// 一个已打开的 socket 及其地址族。
    private struct OpenSocket: Sendable {
        /// 文件描述符。
        let descriptor: Int32
        /// 地址族（`AF_INET` / `AF_INET6`）。
        let family: Int32
    }

    /// 广播目标地址。
    private enum Target: Sendable, Hashable {
        case ipv4(host: String, port: Int)
        case ipv6(host: String, port: Int)

        /// 该目标所属的地址族。
        var family: Int32 {
            switch self {
            case .ipv4: AF_INET
            case .ipv6: AF_INET6
            }
        }
    }

    /// 单次 `poll(2)` 的最长等待（毫秒）。
    ///
    /// 分片等待的目的：`poll` 阻塞期间无法响应 `Task` 取消，
    /// 切成 200ms 一片后最坏延迟只有 200ms，且不会长时间占住 actor。
    private static let pollSliceMilliseconds: Int32 = 200

    /// 单条 UDP 报文的最大长度（发现回包只有几十字节，8192 足够）。
    private static let receiveBufferSize = 8192

    private var sockets: [OpenSocket] = []
    private var targets: [Target] = []
    private var isStarted = false

    /// 创建一个传输通道。真正的 socket 在 ``start(port:)`` 里才打开。
    public init() {}

    // MARK: - DiscoveryTransport

    /// 打开 IPv4 / IPv6 socket 并绑定随机本地端口，同时计算广播目标列表。
    ///
    /// - Parameter port: 目标 UDP 端口（Emby 为 7359）。
    /// - Throws: 两个地址族都无法建立 socket 时抛 ``PrismCore/EmbyError/serverUnreachable(_:)``。
    public func start(port: Int) async throws {
        guard !isStarted else { return }

        var opened: [OpenSocket] = []
        if let socket = Self.openSocket(family: AF_INET) { opened.append(socket) }
        if let socket = Self.openSocket(family: AF_INET6) { opened.append(socket) }
        guard !opened.isEmpty else {
            throw EmbyError.serverUnreachable("无法创建 UDP socket")
        }

        sockets = opened
        targets = Self.broadcastTargets(port: port)
        isStarted = true
    }

    /// 向所有广播目标发送报文（每个地址族各发一份）。
    ///
    /// - Parameter data: 报文正文。
    /// - Throws: 一条都没发出去时抛 ``PrismCore/EmbyError/serverUnreachable(_:)``。
    public func send(_ data: Data) async throws {
        guard isStarted, !sockets.isEmpty else {
            throw EmbyError.serverUnreachable("UDP socket 尚未就绪")
        }

        var delivered = false
        for socket in sockets {
            for target in targets where target.family == socket.family {
                if Self.send(data, to: target, on: socket.descriptor) { delivered = true }
            }
        }
        guard delivered else {
            throw EmbyError.serverUnreachable("UDP 广播发送失败")
        }
    }

    /// 等待下一条回包，直到收到数据、到达 deadline 或任务被取消。
    ///
    /// - Parameter deadline: 本次发现的截止时刻。
    /// - Returns: 收到的报文；超时 / 取消时为 `nil`。
    public func receive(until deadline: ContinuousClock.Instant) async -> DiscoveryDatagram? {
        guard isStarted, !sockets.isEmpty else { return nil }
        let clock = ContinuousClock()

        while !Task.isCancelled {
            let remaining = clock.now.duration(to: deadline)
            if remaining <= .zero { return nil }

            let milliseconds = Int32(clamping: max(1, min(Int64(Self.pollSliceMilliseconds), Int64(remaining.prismSeconds * 1000))))
            var descriptors = sockets.map { pollfd(fd: $0.descriptor, events: Int16(POLLIN), revents: 0) }
            let ready = descriptors.withUnsafeMutableBufferPointer { buffer in
                poll(buffer.baseAddress, nfds_t(buffer.count), milliseconds)
            }
            guard ready > 0 else { continue }

            for (index, descriptor) in descriptors.enumerated() where descriptor.revents & Int16(POLLIN) != 0 {
                if let datagram = Self.readDatagram(from: sockets[index].descriptor) { return datagram }
            }
        }
        return nil
    }

    /// 关闭所有 socket。可重复调用。
    public func cancel() async {
        for socket in sockets { close(socket.descriptor) }
        sockets.removeAll()
        targets.removeAll()
        isStarted = false
    }

    // MARK: - socket 生命周期

    /// 创建并绑定一个 UDP socket。
    ///
    /// - Parameter family: 地址族（`AF_INET` / `AF_INET6`）。
    /// - Returns: 已就绪的 socket；失败时为 `nil`（失败路径会关闭 fd，不泄漏）。
    private static func openSocket(family: Int32) -> OpenSocket? {
        let descriptor = socket(family, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return nil }

        var yes: Int32 = 1
        let optionSize = socklen_t(MemoryLayout<Int32>.size)
        // SO_BROADCAST 是 macOS 上发广播的硬性要求；SO_REUSEADDR 让同一进程的
        // 多个 socket 能共存（也方便调试时反复运行）。
        guard setsockopt(descriptor, SOL_SOCKET, SO_BROADCAST, &yes, optionSize) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &yes, optionSize) == 0,
              bindEphemeral(descriptor: descriptor, family: family)
        else {
            close(descriptor)
            return nil
        }
        return OpenSocket(descriptor: descriptor, family: family)
    }

    /// 绑定到 `0.0.0.0:0` / `[::]:0`（随机本地端口）。
    ///
    /// 不要绑 7359：那是**服务端**的监听端口，客户端占用它会导致广播回包收不到
    /// （见 `docs/research/emby-api.md` §3.1「实现要点」）。
    ///
    /// - Parameters:
    ///   - descriptor: socket 文件描述符。
    ///   - family: 地址族。
    /// - Returns: 是否绑定成功。
    private static func bindEphemeral(descriptor: Int32, family: Int32) -> Bool {
        if family == AF_INET6 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = 0
            address.sin6_addr = in6addr_any
            return withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
                }
            }
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    // MARK: - 广播目标

    /// 计算广播目标：全局广播 + 每块启用中 IPv4 网卡的子网定向广播。
    ///
    /// - Parameter port: 目标端口。
    /// - Returns: 去重后的目标列表；枚举网卡失败时只有全局广播。
    private static func broadcastTargets(port: Int) -> [Target] {
        var targets: [Target] = [.ipv4(host: "255.255.255.255", port: port)]

        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return targets }
        defer { freeifaddrs(pointer) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = cursor {
            cursor = interface.pointee.ifa_next

            guard let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            let flags = Int32(bitPattern: interface.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let netmask = interface.pointee.ifa_netmask else { continue }

            let local = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            guard mask != 0 else { continue }

            // 子网广播地址 = 本机地址 | ~掩码
            var value = in_addr(s_addr: local | ~mask)
            guard let host = ipv4String(&value) else { continue }

            let target = Target.ipv4(host: host, port: port)
            if !targets.contains(target) { targets.append(target) }
        }
        return targets
    }

    // MARK: - 收发

    /// 向单个目标发送报文。
    ///
    /// - Parameters:
    ///   - data: 报文正文。
    ///   - target: 目标地址。
    ///   - descriptor: socket 文件描述符。
    /// - Returns: 是否完整发出。
    private static func send(_ data: Data, to target: Target, on descriptor: Int32) -> Bool {
        guard let destination = makeSockaddr(for: target) else { return false }
        var storage = destination.address
        let sent = data.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            return withUnsafePointer(to: &storage) { pointer -> Int in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    sendto(descriptor, base, buffer.count, 0, sockaddrPointer, destination.length)
                }
            }
        }
        return sent == data.count
    }

    /// 读一条报文（调用前须由 `poll` 确认可读）。
    ///
    /// - Parameter descriptor: socket 文件描述符。
    /// - Returns: 报文与发送方 IP；读取失败时为 `nil`。
    private static func readDatagram(from descriptor: Int32) -> DiscoveryDatagram? {
        var buffer = [UInt8](repeating: 0, count: receiveBufferSize)
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)

        let received = withUnsafeMutablePointer(to: &storage) { pointer -> Int in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                recvfrom(descriptor, &buffer, buffer.count, 0, sockaddrPointer, &length)
            }
        }
        guard received > 0 else { return nil }

        return DiscoveryDatagram(
            data: Data(buffer[0..<received]),
            sourceHost: hostString(from: storage)
        )
    }

    /// 把目标地址转成 C 结构。
    ///
    /// - Parameter target: 目标地址。
    /// - Returns: `sockaddr_storage` 与它的有效长度；地址非法时为 `nil`。
    private static func makeSockaddr(for target: Target) -> (address: sockaddr_storage, length: socklen_t)? {
        var storage = sockaddr_storage()

        switch target {
        case let .ipv4(host, port):
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(UInt16(clamping: port)).bigEndian
            guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return nil }
            withUnsafeBytes(of: address) { source in
                withUnsafeMutableBytes(of: &storage) { destination in
                    destination.copyBytes(from: source)
                }
            }
            return (storage, socklen_t(MemoryLayout<sockaddr_in>.size))

        case let .ipv6(host, port):
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = in_port_t(UInt16(clamping: port)).bigEndian
            guard inet_pton(AF_INET6, host, &address.sin6_addr) == 1 else { return nil }
            withUnsafeBytes(of: address) { source in
                withUnsafeMutableBytes(of: &storage) { destination in
                    destination.copyBytes(from: source)
                }
            }
            return (storage, socklen_t(MemoryLayout<sockaddr_in6>.size))
        }
    }

    // MARK: - 地址字符串

    /// 取 `sockaddr_storage` 里的发送方 IP。
    ///
    /// - Parameter storage: `recvfrom` 填好的地址结构。
    /// - Returns: 点分 / 冒号分隔的 IP；无法识别时为 `nil`。
    private static func hostString(from storage: sockaddr_storage) -> String? {
        var storage = storage
        switch Int32(storage.ss_family) {
        case AF_INET:
            return withUnsafePointer(to: &storage) { pointer -> String? in
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sockaddrPointer in
                    var value = sockaddrPointer.pointee.sin_addr
                    return ipv4String(&value)
                }
            }
        case AF_INET6:
            return withUnsafePointer(to: &storage) { pointer -> String? in
                pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sockaddrPointer in
                    var value = sockaddrPointer.pointee.sin6_addr
                    return ipv6String(&value)
                }
            }
        default:
            return nil
        }
    }

    /// IPv4 地址转字符串。
    ///
    /// - Parameter address: 地址（`inout` 以满足 `inet_ntop` 的指针参数）。
    /// - Returns: 点分十进制字符串。
    private static func ipv4String(_ address: inout in_addr) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return string(from: buffer)
    }

    /// IPv6 地址转字符串。
    ///
    /// - Parameter address: 地址。
    /// - Returns: 冒号分隔字符串。
    private static func ipv6String(_ address: inout in6_addr) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
        return string(from: buffer)
    }

    /// 把 `inet_ntop` 写出的 C 字符串缓冲区转成 `String`。
    ///
    /// - Parameter buffer: 以 `\0` 结尾的缓冲区。
    /// - Returns: 字符串。
    private static func string(from buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

// MARK: - Duration 换算

extension Duration {
    /// 换算成秒（`TimeInterval`）。
    ///
    /// 仅用于把 Swift 的 `Duration` 交给需要秒/毫秒的 C API（`poll`、`URLRequest`）。
    var prismSeconds: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
