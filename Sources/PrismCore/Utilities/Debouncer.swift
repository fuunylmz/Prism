import Foundation

/// 异步防抖器：把短时间内的连续触发合并成最后一次执行。
///
/// 典型用途是搜索框——用户每敲一个字符都会调用 `schedule`，
/// 只有停顿超过 `interval` 后才真正发起请求，避免请求风暴。
///
/// 实现用 actor 保证状态串行，`Task` 负责延迟；每次新调用都会取消上一个待执行任务。
///
/// ```swift
/// let debouncer = Debouncer(interval: .milliseconds(300))
/// for query in typingSequence {
///     await debouncer.schedule { await viewModel.search(query) }
/// }
/// ```
public actor Debouncer {
    /// 防抖间隔。
    private let interval: Duration
    /// 当前挂起的任务。
    private var pendingTask: Task<Void, Never>?
    /// 单调递增的序号，用于丢弃过期任务（防止取消竞态）。
    private var generation = 0

    /// 创建防抖器。
    ///
    /// - Parameter interval: 静默间隔，默认 300ms。
    public init(interval: Duration = .milliseconds(300)) {
        self.interval = interval
    }

    /// 安排一次延迟执行；会取消上一个尚未触发的任务。
    ///
    /// - Parameter operation: 到达静默期后执行的动作。
    public func schedule(_ operation: @escaping @Sendable () async -> Void) {
        generation += 1
        let currentGeneration = generation
        pendingTask?.cancel()
        pendingTask = Task { [interval] in
            do {
                try await Task.sleep(for: interval)
            } catch {
                return // 被取消，直接退出
            }
            guard !Task.isCancelled else { return }
            await Self.runIfCurrent(owner: self, generation: currentGeneration, operation)
        }
    }

    /// 立即执行并清空挂起任务（例如用户按下回车）。
    ///
    /// - Parameter operation: 要立刻执行的动作。
    public func flush(_ operation: @Sendable () async -> Void) async {
        generation += 1
        pendingTask?.cancel()
        pendingTask = nil
        await operation()
    }

    /// 取消挂起任务。
    public func cancel() {
        generation += 1
        pendingTask?.cancel()
        pendingTask = nil
    }

    /// 是否有挂起任务。
    public var isPending: Bool {
        pendingTask != nil && !(pendingTask?.isCancelled ?? true)
    }

    /// 仅当序号仍是最新时才执行，避免“取消后旧任务仍落地”的竞态。
    private static func runIfCurrent(
        owner: Debouncer,
        generation: Int,
        _ operation: @Sendable () async -> Void
    ) async {
        let isCurrent = await owner.isCurrent(generation: generation)
        guard isCurrent else { return }
        await operation()
    }

    /// 判断给定序号是否仍是当前序号。
    private func isCurrent(generation other: Int) -> Bool {
        other == generation
    }
}
