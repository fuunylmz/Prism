import Foundation

/// 滚动预取器：把「下一屏可能会看到的图」提前拉进缓存。
///
/// 与 ``ImageLoading/prefetch(_:limit:)`` 的分工：
/// - 加载器负责**一次**预取的并发与优先级；
/// - 预取器负责**多次**入队之间的合并、去重与取消。滚动时 UI 会频繁调用
///   `enqueue`（每帧都可能），不能每次都起一批任务打服务器，所以这里维护一个队列，
///   由单个后台 worker 顺序消化。
///
/// 取消语义：``cancel()`` 取消当前 worker 并清空队列；worker 内部每一批都会把取消
/// 状态传给 ``ImageLoading/prefetch(_:limit:)``，已取消的批次不会再发起新下载
/// （正在进行的下载最多跑完，不会无限扩张）。
///
/// ```swift
/// let prefetcher = ImagePrefetcher(loader: loader)
/// prefetcher.enqueue(items.prefix(24).map { .poster(itemId: $0.id, tag: $0.primaryImageTag) })
/// // 离开页面
/// prefetcher.cancel()
/// ```
public actor ImagePrefetcher {
    private let loader: any ImageLoading

    /// 每批最多处理多少个。
    private let batchSize: Int

    private var pending: [ImageRequest] = []
    private var queuedKeys: Set<String> = []
    private var worker: Task<Void, Never>?
    /// 代际号：避免旧 worker 结束时把新 worker 的引用清掉。
    private var generation = 0

    /// 创建预取器。
    ///
    /// - Parameters:
    ///   - loader: 实际加载器（``EmbyImageLoader`` 或任意 ``ImageLoading`` 实现）。
    ///   - batchSize: 每批最多处理多少个，默认 8。
    public init(loader: any ImageLoading, batchSize: Int = 8) {
        self.loader = loader
        self.batchSize = max(1, batchSize)
    }

    /// 队列中还没开始处理的请求数。
    public var pendingCount: Int {
        pending.count
    }

    /// 是否有 worker 在跑。
    public var isRunning: Bool {
        worker != nil
    }

    /// 入队一批请求。
    ///
    /// 重复的键（同一张图）在队列里只保留一份。调用方可以按滚动位置反复调用。
    ///
    /// - Parameter requests: 待预取请求。
    public func enqueue(_ requests: [ImageRequest]) {
        guard !requests.isEmpty else { return }
        for request in requests where !queuedKeys.contains(request.cacheKey) {
            queuedKeys.insert(request.cacheKey)
            pending.append(request)
        }
        startIfNeeded()
    }

    /// 取消全部预取并清空队列。
    public func cancel() {
        generation += 1
        worker?.cancel()
        worker = nil
        pending.removeAll()
        queuedKeys.removeAll()
    }

    /// 等待当前队列被消化完。
    ///
    /// 主要用于测试与「退出前把预取跑完」；UI 不需要等它。
    public func waitUntilIdle() async {
        while let current = worker {
            await current.value
        }
    }

    // MARK: - 内部

    /// 没有 worker 且队列非空时启动一个。
    private func startIfNeeded() {
        guard worker == nil, !pending.isEmpty else { return }
        generation += 1
        let token = generation
        worker = Task { [weak self] in
            await self?.drain(generation: token)
        }
    }

    /// 顺序消化队列，每批交给加载器。
    private func drain(generation token: Int) async {
        while !pending.isEmpty {
            if Task.isCancelled {
                break
            }
            let batch = Array(pending.prefix(batchSize))
            pending.removeFirst(batch.count)
            for request in batch {
                queuedKeys.remove(request.cacheKey)
            }
            await loader.prefetch(batch, limit: batch.count)
        }

        // 只有自己还是「当前代」时才清引用：cancel() 之后可能已经起了新 worker。
        if generation == token {
            worker = nil
        }
    }
}
