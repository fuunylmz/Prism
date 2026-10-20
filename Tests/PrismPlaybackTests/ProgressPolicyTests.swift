import Foundation
import PrismCore
import Testing

@testable import PrismPlayback

// MARK: - 续播策略

@Suite("ResumePolicy：续播与完播判定")
struct ResumePolicyTests {
    /// 造一个带观看进度的条目。
    ///
    /// - Parameters:
    ///   - position: 上次播放位置。
    ///   - duration: 总时长。
    ///   - played: 服务端是否已标记看完。
    /// - Returns: 媒体条目。
    private func item(position: Ticks, duration: Ticks?, played: Bool = false) -> MediaItem {
        MediaItem(
            id: "item-1",
            name: "Test Movie",
            type: .movie,
            serverId: "server-1",
            runTime: duration,
            userData: UserItemData(
                playbackPosition: position,
                playCount: played ? 1 : 0,
                isFavorite: false,
                played: played,
                lastPlayedDate: nil,
                unplayedItemCount: nil
            )
        )
    }

    @Test("看过一半 → 返回 位置 - 回退（300s → 297s）")
    func resumesWithRewind() throws {
        let policy = ResumePolicy()
        let resume = policy.resumePosition(for: item(position: Ticks(seconds: 300), duration: Ticks(seconds: 600)))
        let value = try #require(resume)
        #expect(value == Ticks(seconds: 297))
    }

    @Test("未看过 → nil")
    func neverPlayedReturnsNil() {
        let policy = ResumePolicy()
        #expect(policy.resumePosition(for: item(position: .zero, duration: Ticks(seconds: 600))) == nil)
    }

    @Test("位置不足 30 秒 → nil（太短不续播）")
    func tooShortReturnsNil() {
        let policy = ResumePolicy()
        #expect(policy.resumePosition(for: item(position: Ticks(seconds: 20), duration: Ticks(seconds: 600))) == nil)
        // 恰好等于阈值 → 可以续播（边界包含）。
        #expect(
            policy.resumePosition(for: item(position: Ticks(seconds: 30), duration: Ticks(seconds: 600)))
                == Ticks(seconds: 27)
        )
    }

    @Test("回退不越界：2 秒位置 → 0 而不是负数")
    func rewindClampsToZero() {
        let policy = ResumePolicy()
        #expect(policy.resumePosition(for: item(position: Ticks(seconds: 2), duration: Ticks(seconds: 600))) == nil)

        // 把阈值降到 0，强制走到回退分支，验证钳零。
        var relaxed = ResumePolicy()
        relaxed.minimumResumePosition = .zero
        #expect(relaxed.resumePosition(for: item(position: Ticks(seconds: 2), duration: Ticks(seconds: 600))) == .zero)
    }

    @Test("完播：95 / 100 → isCompleted 为 true，resumePosition 为 nil")
    func completedItemStartsOver() {
        let policy = ResumePolicy()
        let position = Ticks(seconds: 95)
        let duration = Ticks(seconds: 100)

        #expect(policy.isCompleted(position: position, duration: duration))
        #expect(policy.resumePosition(for: item(position: position, duration: duration)) == nil)
    }

    @Test("90% 边界：恰好 90% 算完播，89.9% 不算")
    func completionThresholdBoundary() {
        let policy = ResumePolicy()
        let duration = Ticks(seconds: 100)

        #expect(policy.isCompleted(position: Ticks(seconds: 90), duration: duration))
        #expect(!policy.isCompleted(position: Ticks(seconds: 89), duration: duration))
        #expect(policy.isCompleted(position: Ticks(seconds: 100), duration: duration))
    }

    @Test("服务端已标记 played → nil（即使位置很低）")
    func serverPlayedFlagWins() {
        let policy = ResumePolicy()
        let played = item(position: Ticks(seconds: 200), duration: Ticks(seconds: 600), played: true)
        #expect(policy.resumePosition(for: played) == nil)
    }

    @Test("时长未知（直播 / 未入库）→ 不按百分比拦截，仍可续播")
    func unknownDurationStillResumes() throws {
        let policy = ResumePolicy()
        let resume = policy.resumePosition(for: item(position: Ticks(seconds: 300), duration: nil))
        let value = try #require(resume)
        #expect(value == Ticks(seconds: 297))
    }

    @Test("自定义策略：回退 10 秒、阈值 80%")
    func customPolicy() throws {
        let policy = ResumePolicy(
            minimumResumePosition: Ticks(seconds: 60),
            completionThreshold: 0.80,
            rewindOnResume: Ticks(seconds: 10)
        )

        #expect(policy.resumePosition(for: item(position: Ticks(seconds: 50), duration: Ticks(seconds: 600))) == nil)

        let resume = policy.resumePosition(for: item(position: Ticks(seconds: 300), duration: Ticks(seconds: 600)))
        let value = try #require(resume)
        #expect(value == Ticks(seconds: 290))

        // 80% 阈值：81% 已算看完。
        #expect(policy.resumePosition(for: item(position: Ticks(seconds: 486), duration: Ticks(seconds: 600))) == nil)
        #expect(policy.isCompleted(position: Ticks(seconds: 480), duration: Ticks(seconds: 600)))
    }

    @Test("时长非法（0）→ 永不判定完播")
    func zeroDurationNeverCompletes() {
        let policy = ResumePolicy()
        #expect(!policy.isCompleted(position: Ticks(seconds: 100), duration: .zero))
        #expect(!policy.isCompleted(position: Ticks(seconds: 100), duration: Ticks(seconds: -5)))
    }
}

// MARK: - 节流器

@Suite("ProgressThrottler：节流与去重")
struct ProgressThrottlerTests {
    // 说明：`shouldReport` 是 mutating 的，不能直接写进 `#expect(...)`——
    // `#expect` 会把表达式包进闭包，对 mutating 成员报
    // "cannot use mutating member on immutable value"。所以先取局部变量再断言。

    @Test("首次调用总是放行")
    func firstCallAlwaysReports() {
        var throttler = ProgressThrottler()
        let allowed = throttler.shouldReport(
            position: .zero,
            isInteraction: false,
            now: Date(timeIntervalSince1970: 0)
        )
        #expect(allowed)
    }

    @Test("10 秒窗口内不重复放行")
    func suppressedWithinInterval() {
        var throttler = ProgressThrottler()
        let start = Date(timeIntervalSince1970: 1_000)

        let first = throttler.shouldReport(position: Ticks(seconds: 10), isInteraction: false, now: start)
        #expect(first)

        let tooSoon = throttler.shouldReport(
            position: Ticks(seconds: 15),
            isInteraction: false,
            now: start.addingTimeInterval(5)
        )
        #expect(!tooSoon)

        let afterWindow = throttler.shouldReport(
            position: Ticks(seconds: 20),
            isInteraction: false,
            now: start.addingTimeInterval(10)
        )
        #expect(afterWindow)
    }

    @Test("交互事件无视时间窗口")
    func interactionBypassesInterval() {
        var throttler = ProgressThrottler()
        let start = Date(timeIntervalSince1970: 1_000)

        let first = throttler.shouldReport(position: Ticks(seconds: 10), isInteraction: false, now: start)
        #expect(first)

        let interaction = throttler.shouldReport(
            position: Ticks(seconds: 10),
            isInteraction: true,
            now: start.addingTimeInterval(0.1)
        )
        #expect(interaction)
    }

    @Test("位置变化 < 1 秒跳过")
    func tinyDeltaSkipped() {
        var throttler = ProgressThrottler()
        let start = Date(timeIntervalSince1970: 1_000)

        let first = throttler.shouldReport(position: Ticks(seconds: 10), isInteraction: false, now: start)
        #expect(first)

        let tinyDelta = throttler.shouldReport(
            position: Ticks(seconds: 10.5),
            isInteraction: false,
            now: start.addingTimeInterval(60)
        )
        #expect(!tinyDelta)
    }

    @Test("reset 后回到初始状态")
    func resetClearsState() {
        var throttler = ProgressThrottler()
        let start = Date(timeIntervalSince1970: 1_000)

        let first = throttler.shouldReport(position: Ticks(seconds: 10), isInteraction: false, now: start)
        #expect(first)

        throttler.reset()
        let afterReset = throttler.shouldReport(position: Ticks(seconds: 10), isInteraction: false, now: start)
        #expect(afterReset)
    }

    @Test("Duration → 秒的换算")
    func durationConversion() {
        #expect(ProgressThrottler.seconds(from: .seconds(10)) == 10)
        #expect(ProgressThrottler.seconds(from: .milliseconds(500)) == 0.5)
        #expect(ProgressThrottler.seconds(from: .seconds(1)) == 1)
    }
}
