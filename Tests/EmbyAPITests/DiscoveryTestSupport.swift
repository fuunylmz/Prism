import Foundation
import Testing
@testable import EmbyAPI
import PrismCore

/// 脚本化的假传输通道。
///
/// 测试用它替代真实 UDP：按顺序吐出预设回包，或干脆什么都不吐（模拟「网络上没有服务器」）。
/// 全部状态由 `LockedBox` 保护，满足 `Sendable`，可安全穿过 actor 边界。
final class FakeDiscoveryTransport: DiscoveryTransport, @unchecked Sendable {
    /// 记录下来的调用行为，供断言使用。
    struct Recorded: Sendable, Equatable {
        /// `start` 收到的端口。
        var startedPort: Int?
        /// `send` 收到的报文。
        var sentPayloads: [Data] = []
        /// `cancel` 被调用了几次。
        var cancelCount = 0
    }

    private let state = LockedBox(State())

    private struct State: Sendable {
        var recorded = Recorded()
        var queue: [DiscoveryDatagram] = []
        var startError: EmbyError?
        var sendError: EmbyError?
    }

    /// 构造脚本化通道。
    ///
    /// - Parameters:
    ///   - datagrams: 按顺序吐出的回包；吐完即「网络安静」，`receive` 会等到 deadline。
    ///   - startError: 让 `start` 抛错（模拟 socket 建不起来）。
    ///   - sendError: 让 `send` 抛错（模拟广播发不出去）。
    init(
        datagrams: [DiscoveryDatagram] = [],
        startError: EmbyError? = nil,
        sendError: EmbyError? = nil
    ) {
        state.withLock {
            $0.queue = datagrams
            $0.startError = startError
            $0.sendError = sendError
        }
    }

    /// 便捷构造：用 JSON 文本作为回包，源 IP 可选。
    ///
    /// - Parameter payloads: `(json, sourceHost)` 列表。
    convenience init(payloads: [(json: String, sourceHost: String?)]) {
        self.init(datagrams: payloads.map {
            DiscoveryDatagram(data: Data($0.json.utf8), sourceHost: $0.sourceHost)
        })
    }

    /// 当前记录的行为快照。
    var recorded: Recorded {
        state.withLock { $0.recorded }
    }

    // MARK: - DiscoveryTransport

    func start(port: Int) async throws {
        let error: EmbyError? = state.withLock {
            $0.recorded.startedPort = port
            return $0.startError
        }
        if let error { throw error }
    }

    func send(_ data: Data) async throws {
        let error: EmbyError? = state.withLock {
            $0.recorded.sentPayloads.append(data)
            return $0.sendError
        }
        if let error { throw error }
    }

    func receive(until deadline: ContinuousClock.Instant) async -> DiscoveryDatagram? {
        if let next = state.withLock({ $0.queue.isEmpty ? nil : $0.queue.removeFirst() }) {
            return next
        }
        // 队列空了：模拟「网络安静」——等到 deadline 再返回 nil，
        // 顺便验证 ServerDiscovery 不会提前结束流。
        let clock = ContinuousClock()
        let remaining = clock.now.duration(to: deadline)
        if remaining > .zero {
            try? await clock.sleep(until: deadline)
        }
        return nil
    }

    func cancel() async {
        state.withLock { $0.recorded.cancelCount += 1 }
    }
}

/// 一把最小可用的互斥锁（不直接用 `Synchronization.Mutex`，避免与测试里的类型名混淆）。
final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    /// 创建锁。
    ///
    /// - Parameter value: 初始值。
    init(_ value: Value) {
        self.value = value
    }

    /// 加锁读写。
    ///
    /// - Parameter body: 临界区。
    /// - Returns: `body` 的返回值。
    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
