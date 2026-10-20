import EmbyAPI
import Foundation
import PrismCore
import Testing

@testable import PrismPlayback

// MARK: - 离线队列

@Suite("PendingProgressQueue：离线补报队列")
struct PendingProgressQueueTests {
    /// 造一条进度上报。
    ///
    /// - Parameter seconds: 位置（秒），用作唯一标识。
    /// - Returns: 待补报条目。
    private func progress(_ seconds: Double) -> PendingProgressReport {
        var report = PlaybackProgressReport(itemId: "item-1", positionTicks: Ticks(seconds: seconds))
        report.eventName = .timeUpdate
        return .progress(report)
    }

    @Test("按入队顺序 drain，全部成功时清空")
    func drainsInOrder() async {
        let recorder = SentRecorder()
        let queue = PendingProgressQueue(capacity: 10) { report in
            await recorder.record(report)
        }

        await queue.enqueue(progress(1))
        await queue.enqueue(progress(2))
        await queue.enqueue(progress(3))

        let sent = await queue.drain()
        #expect(sent == 3)

        let count = await queue.count
        #expect(count == 0)

        let recorded = await recorder.snapshot()
        #expect(recorded.count == 3)
        #expect(recorded == [progress(1), progress(2), progress(3)])
    }

    @Test("发送失败时保留该条并停止本轮")
    func stopsOnFirstFailure() async {
        let recorder = SentRecorder()
        let queue = PendingProgressQueue(capacity: 10) { report in
            if case let .progress(payload) = report,
               payload.positionTicks == Ticks(seconds: 2) {
                throw EmbyError.serverUnreachable("offline")
            }
            await recorder.record(report)
        }

        await queue.enqueue(progress(1))
        await queue.enqueue(progress(2))
        await queue.enqueue(progress(3))

        let sent = await queue.drain()
        #expect(sent == 1, "第 2 条失败后应停止本轮")

        let remaining = await queue.snapshot()
        #expect(remaining == [progress(2), progress(3)])

        // 恢复后再 drain，能继续把剩下的发完。
        let recorder2 = SentRecorder()
        let queue2 = PendingProgressQueue(capacity: 10) { report in
            await recorder2.record(report)
        }
        await queue2.enqueue(progress(2))
        await queue2.enqueue(progress(3))
        let sent2 = await queue2.drain()
        #expect(sent2 == 2)
    }

    @Test("队列上限：超过 50 条时丢最旧的")
    func dropsOldestBeyondCapacity() async {
        let queue = PendingProgressQueue { _ in }
        for step in 1...60 {
            await queue.enqueue(progress(Double(step)))
        }

        let count = await queue.count
        #expect(count == PendingProgressQueue.defaultCapacity, "容量应为 50，实际 \(count)")

        let snapshot = await queue.snapshot()
        // 丢掉了 1...10，队首应是 11，队尾应是 60。
        #expect(snapshot.first == progress(11))
        #expect(snapshot.last == progress(60))
    }

    @Test("自定义容量：capacity = 3 时只留最新 3 条")
    func customCapacity() async {
        let queue = PendingProgressQueue(capacity: 3) { _ in }
        for step in 1...5 {
            await queue.enqueue(progress(Double(step)))
        }
        let snapshot = await queue.snapshot()
        #expect(snapshot == [progress(3), progress(4), progress(5)])
    }

    @Test("capacity 非法（0 / 负数）按 1 处理")
    func invalidCapacityClampsToOne() async {
        let queue = PendingProgressQueue(capacity: 0) { _ in }
        let capacity = await queue.capacity
        #expect(capacity == 1)

        await queue.enqueue(progress(1))
        await queue.enqueue(progress(2))
        let snapshot = await queue.snapshot()
        #expect(snapshot == [progress(2)])
    }

    @Test("空队列 drain 返回 0，不调用 sender")
    func emptyDrainDoesNothing() async {
        let recorder = SentRecorder()
        let queue = PendingProgressQueue { report in
            await recorder.record(report)
        }
        let sent = await queue.drain()
        #expect(sent == 0)
        let recorded = await recorder.snapshot()
        #expect(recorded.isEmpty)
    }

    @Test("removeAll 清空队列")
    func removeAllClears() async {
        let queue = PendingProgressQueue { _ in }
        await queue.enqueue(progress(1))
        await queue.removeAll()
        let isEmpty = await queue.isEmpty
        #expect(isEmpty)
    }

    @Test("stop 上报在队列里保持自己的类型，不会被当成 progress")
    func preservesReportKind() async {
        let recorder = SentRecorder()
        let queue = PendingProgressQueue(capacity: 10) { report in
            await recorder.record(report)
        }

        let stop = PendingProgressReport.stop(
            PlaybackStopReport(itemId: "item-1", positionTicks: Ticks(seconds: 7))
        )
        await queue.enqueue(stop)
        await queue.drain()

        let recorded = await recorder.snapshot()
        #expect(recorded.count == 1)
        guard let first = recorded.first, case let .stop(payload) = first else {
            Issue.record("应保留 .stop 类型")
            return
        }
        #expect(payload.positionTicks == Ticks(seconds: 7))
        #expect(recorded.first?.itemId == "item-1")
    }
}

// MARK: - 记录器

/// 记录被发送的上报（actor，供 `@Sendable` 闭包安全写入）。
actor SentRecorder {
    private var storage: [PendingProgressReport] = []

    /// 追加一条。
    ///
    /// - Parameter report: 已发送的上报。
    func record(_ report: PendingProgressReport) {
        storage.append(report)
    }

    /// 当前快照。
    ///
    /// - Returns: 按发送顺序排列的上报。
    func snapshot() -> [PendingProgressReport] {
        storage
    }
}
