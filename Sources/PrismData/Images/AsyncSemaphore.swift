import Foundation

/// 带优先级的异步信号量，用来限制同时进行的图片下载数。
///
/// 为什么不用 `DispatchSemaphore`：`wait()` 会阻塞线程（`@available(*, noasync)`），
/// 在 Swift 并发的任务里阻塞线程可能把协作线程池耗干。这里用 `CheckedContinuation`
/// 挂起任务，让出线程。
///
/// 为什么需要优先级：``EmbyImageLoader/prefetch(_:limit:)`` 是低优先级的后台预取，
/// 可见区域的海报是高优先级。如果只做 FIFO，一次预取就能把 6 个下载名额全占住，
/// 用户正在看的图要排在后面。高优先级等待者会被优先放行。
///
/// - Note: 本类型**不**处理取消。等待中的任务在拿到名额后自行检查 `Task.isCancelled`
///   并释放名额（``EmbyImageLoader`` 就是这么做的），这样不会出现「取消后名额泄漏」。
final class AsyncSemaphore: @unchecked Sendable {
    /// 等待优先级。
    enum Priority: Sendable {
        /// 可见区域、用户正在等。
        case high
        /// 后台预取。
        case low
    }

    /// 同时允许的数量。
    let limit: Int

    private let lock = NSLock()
    private var available: Int
    private var highWaiters: [CheckedContinuation<Void, Never>] = []
    private var lowWaiters: [CheckedContinuation<Void, Never>] = []

    /// 创建信号量。
    ///
    /// - Parameter limit: 同时允许的数量，小于 1 时按 1 处理。
    init(limit: Int) {
        let clamped = max(1, limit)
        self.limit = clamped
        available = clamped
    }

    /// 当前剩余名额（测试与诊断用）。
    var availablePermits: Int {
        lock.lock()
        defer { lock.unlock() }
        return available
    }

    /// 当前等待中的任务数（测试与诊断用）。
    var waitingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return highWaiters.count + lowWaiters.count
    }

    /// 申请一个名额；没有空位时挂起。
    ///
    /// - Parameter priority: 等待优先级。只在**需要排队**时起作用。
    func acquire(priority: Priority) async {
        if takePermitIfAvailable() {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            enqueue(continuation, priority: priority)
        }
    }

    /// 有空位就立刻占用。
    ///
    /// 拆成同步方法：`NSLock.lock()` 在异步上下文里被标记为不可用
    /// （`NS_SWIFT_UNAVAILABLE_FROM_ASYNC`），必须先跳出 async 函数再加锁。
    private func takePermitIfAvailable() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard available > 0 else { return false }
        available -= 1
        return true
    }

    /// 释放一个名额。
    ///
    /// 有等待者时**直接移交给**优先级最高的那个（名额总数不变），否则归还。
    func release() {
        lock.lock()
        let next: CheckedContinuation<Void, Never>?
        if !highWaiters.isEmpty {
            next = highWaiters.removeFirst()
        } else if !lowWaiters.isEmpty {
            next = lowWaiters.removeFirst()
        } else {
            next = nil
            available += 1
        }
        lock.unlock()

        // 在锁外恢复：continuation 可能在同一个任务里同步继续执行并再次调用 acquire。
        next?.resume()
    }

    /// 入队。必须在锁内二次检查空位：`acquire` 解锁到这里的间隙里可能刚好有人释放。
    private func enqueue(_ continuation: CheckedContinuation<Void, Never>, priority: Priority) {
        lock.lock()
        if available > 0 {
            available -= 1
            lock.unlock()
            continuation.resume()
            return
        }
        switch priority {
        case .high:
            highWaiters.append(continuation)
        case .low:
            lowWaiters.append(continuation)
        }
        lock.unlock()
    }
}
