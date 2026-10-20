import EmbyAPI
import Foundation
import PrismCore

/// 一条待补报的进度上报。
///
/// 之所以要分三种而不是统一成一个结构：三个端点的**请求体类型不同**
/// （``PlaybackProgressReport`` 30 字段 / ``PlaybackStopReport`` 14 字段），
/// 补报时必须按原始端点重放，否则就会把 30 字段的结构误发给 `/Sessions/Playing/Stopped`
/// （这正是 T3.4 的核心回归点）。
public enum PendingProgressReport: Sendable, Equatable {
    /// `POST /Sessions/Playing`。
    case start(PlaybackProgressReport)
    /// `POST /Sessions/Playing/Progress`。
    case progress(PlaybackProgressReport)
    /// `POST /Sessions/Playing/Stopped`。
    case stop(PlaybackStopReport)

    /// 该上报对应的条目 id（补报失败时打日志用）。
    public var itemId: String {
        switch self {
        case let .start(report): report.itemId
        case let .progress(report): report.itemId
        case let .stop(report): report.itemId
        }
    }
}

/// 离线进度补报队列（**仅内存**）。
///
/// ## 为什么需要它
///
/// 进度上报是典型的「失败了也不能影响播放」的旁路请求：
/// 网络抖一下、笔记本合盖、服务器重启，都不该让用户丢进度。
/// 官方文档也要求客户端在上报失败后不要阻塞播放：
///
/// > Playback progress should be reported … The server will automatically increment
/// > playback progress every second, so it is not necessary to automatically report
/// > more often than at 10 second intervals.
///
/// - ✅ 来源：<https://dev.emby.media/doc/restapi/Playback-Check-ins.html>
///
/// 本队列在内存里存最近的若干条上报，等下一次网络可用时按原顺序重放。
///
/// ## 容量与淘汰
///
/// 容量默认 ``defaultCapacity``（50）条。写入时若已满，**丢弃最旧的一条**
/// （即「最久未被入队的」，对只追加的队列而言等价于 LRU）。
/// 丢弃时不做任何网络请求，因此不会在断网时堆积。
///
/// ## 刻意不做的事
///
/// - **不落盘**：v1.0 简化，进程被杀就丢。v1.1 换成 `PrismData` 的 GRDB
///   （`ARCHITECTURE §4` 里 `MediaCache.pendingProgress()` 的位置），届时本类型只保留
///   「发送 + 淘汰」逻辑，存储换成可注入的协议。
/// - **不合并**：同一会话的多次 `TimeUpdate` 会原样排队。合并成「只留最新一条」是
///   可行的优化（能显著减少补报流量），但会改变「按发生顺序重放」的语义，
///   留到 v1.1 和持久化一起做。
///
/// ## 线程模型
///
/// `actor`。发送闭包 ``sender`` 在 actor 内部被 `await` 调用，因此 `drain()` 期间
/// actor 是可重入的（此时仍可 `enqueue`，不会死锁）。
public actor PendingProgressQueue {
    /// 默认容量（条）。
    public static let defaultCapacity = 50

    /// 容量上限（条）。
    public let capacity: Int

    /// 待补报条目，按入队顺序排列（下标 0 最旧）。
    private var storage: [PendingProgressReport] = []

    /// 真正发请求的闭包；由调用方注入，便于测试替换成记录器。
    private let sender: @Sendable (PendingProgressReport) async throws -> Void

    /// 防止并发 `drain()` 重复发送同一条。
    private var isDraining = false

    /// 创建队列。
    ///
    /// - Parameters:
    ///   - capacity: 容量，默认 ``defaultCapacity``；小于 1 时按 1 处理。
    ///   - sender: 发送一条上报的闭包。抛错表示「网络仍不可用」，
    ///     `drain()` 会保留该条并停止本轮补报。
    public init(
        capacity: Int = PendingProgressQueue.defaultCapacity,
        sender: @escaping @Sendable (PendingProgressReport) async throws -> Void
    ) {
        self.capacity = max(1, capacity)
        self.sender = sender
    }

    /// 当前排队的条数。
    public var count: Int { storage.count }

    /// 队列是否为空。
    public var isEmpty: Bool { storage.isEmpty }

    /// 入队一条上报；队列已满时丢弃最旧的一条。
    ///
    /// - Parameter report: 待补报的上报。
    public func enqueue(_ report: PendingProgressReport) {
        storage.append(report)
        while storage.count > capacity {
            storage.removeFirst()
        }
    }

    /// 按入队顺序补报，直到队列空或发送失败。
    ///
    /// 失败时**保留**该条（下次再试）并立即结束本轮，不再继续尝试后面的条目——
    /// 断网时逐条重试只会白白拖慢 `stop` 之类的调用方。
    ///
    /// - Returns: 本轮成功发出的条数。
    @discardableResult
    public func drain() async -> Int {
        guard !isDraining else { return 0 }
        isDraining = true
        defer { isDraining = false }

        var sent = 0
        while let next = storage.first {
            do {
                try await sender(next)
            } catch {
                return sent
            }
            // 发送期间可能有新的入队 / 淘汰，因此重新确认队首仍是刚发出去的那条。
            if storage.first == next {
                storage.removeFirst()
            }
            sent += 1
        }
        return sent
    }

    /// 当前队列内容的快照（测试与诊断用）。
    ///
    /// - Returns: 按入队顺序排列的上报。
    public func snapshot() -> [PendingProgressReport] {
        storage
    }

    /// 清空队列（登出、切换服务器时调用）。
    public func removeAll() {
        storage.removeAll()
    }
}
