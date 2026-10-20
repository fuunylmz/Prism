import Foundation
import PrismCore

/// 进度上报的节流与去重决策器。
///
/// 把「这次该不该真的发一个 `/Sessions/Playing/Progress`」这件事从
/// ``ProgressReporter`` 里拆出来，好处是它变成**纯逻辑 + 注入时钟**，
/// 测试里可以用 ``PrismCore/FixedClock`` 或测试自带的可变时钟把 10 秒走完，
/// 不需要 `Task.sleep` 真的等 10 秒。
///
/// ## 规则（来自 Emby 官方）
///
/// 官方 Playback-Check-ins 文档写明：
///
/// > Playback progress should be reported at the following times: Automatically every
/// > 10 seconds; Immediately following any user interaction … The server will automatically
/// > increment playback progress every second, so it is not necessary to automatically report
/// > more often than at 10 second intervals.
///
/// - ✅ 来源：<https://dev.emby.media/doc/restapi/Playback-Check-ins.html>
///
/// 本类型据此实现三条规则：
///
/// 1. **交互事件立即放行**（暂停 / 恢复 / seek / 切音轨 / 切字幕…），不看时间窗口。
/// 2. **去重**：位置相对上次成功上报的变化小于 ``minimumDelta``（默认 1 秒）且不是交互事件
///    → 跳过。这条**先于**时间判断执行：即使 10 秒窗口已过，只要位置没动就继续跳过
///    （典型场景是缓冲卡住，此时重复上报同一个位置没有意义）。
/// 3. **定时**：距上次成功上报已过 ``interval``（默认 10 秒）→ 放行。
///
/// ## 用法
///
/// ```swift
/// var throttler = ProgressThrottler()
/// if throttler.shouldReport(position: pos, isInteraction: false, now: clock.now) {
///     try await sendProgress(pos)
/// }
/// ```
///
/// - Important: ``shouldReport(position:isInteraction:now:)`` 在返回 `true` 时**会顺手记下**
///   本次上报的时间与位置。因此它是有副作用的判定，不要拿它当纯查询用。
public struct ProgressThrottler: Sendable {
    /// 定时上报的间隔，默认 10 秒（Emby 官方建议值）。
    public var interval: Duration

    /// 位置去重阈值：变化小于该值且非交互事件时跳过，默认 1 秒。
    public var minimumDelta: Ticks

    /// 上次**成功放行**的时刻；`nil` 表示还没放过。
    private var lastReportedAt: Date?

    /// 上次**成功放行**时的播放位置；`nil` 表示还没放过。
    private var lastReportedPosition: Ticks?

    /// 创建节流器。
    ///
    /// - Parameters:
    ///   - interval: 定时上报间隔，默认 `.seconds(10)`。
    ///   - minimumDelta: 位置去重阈值，默认 1 秒。
    public init(interval: Duration = .seconds(10), minimumDelta: Ticks = Ticks(seconds: 1)) {
        self.interval = interval
        self.minimumDelta = minimumDelta
    }

    /// ``interval`` 换算成秒，便于与 `Date` 的差值比较。
    public var intervalSeconds: TimeInterval {
        Self.seconds(from: interval)
    }

    /// 判断本次上报是否应当真的发出去；放行时**记录**本次时间与位置。
    ///
    /// - Parameters:
    ///   - position: 引擎给出的当前位置。
    ///   - isInteraction: 是否由用户交互触发（暂停 / 恢复 / seek / 切轨…）。
    ///     交互事件不受时间窗口与去重限制，一律放行。
    ///   - now: 当前时刻，由注入的时钟提供。
    /// - Returns: `true` 表示应当发出请求（并已记录）；`false` 表示跳过。
    public mutating func shouldReport(position: Ticks, isInteraction: Bool, now: Date) -> Bool {
        if isInteraction {
            record(position: position, at: now)
            return true
        }

        // 规则 2：位置几乎没变 → 跳过（缓冲卡住时避免刷同一个位置）。
        if let lastPosition = lastReportedPosition,
           abs(position.rawValue - lastPosition.rawValue) < minimumDelta.rawValue {
            return false
        }

        // 规则 3：还没到 10 秒窗口 → 跳过。
        if let lastAt = lastReportedAt, now.timeIntervalSince(lastAt) < intervalSeconds {
            return false
        }

        record(position: position, at: now)
        return true
    }

    /// 清空内部状态。
    ///
    /// 用于开始播放新的条目、或 `start` 成功后重新计时。
    public mutating func reset() {
        lastReportedAt = nil
        lastReportedPosition = nil
    }

    /// 手动记录一次「已经发出去」的上报。
    ///
    /// 当上报由 ``shouldReport(position:isInteraction:now:)`` 之外的路径触发
    /// （例如 `start` 已经发过一次 `POST /Sessions/Playing`）时，用它把节流窗口对齐。
    ///
    /// - Parameters:
    ///   - position: 本次上报的位置。
    ///   - now: 本次上报的时刻。
    public mutating func markReported(position: Ticks, at now: Date) {
        record(position: position, at: now)
    }

    /// 记录内部状态。
    ///
    /// - Parameters:
    ///   - position: 本次上报的位置。
    ///   - now: 本次上报的时刻。
    private mutating func record(position: Ticks, at now: Date) {
        lastReportedAt = now
        lastReportedPosition = position
    }

    /// 把 `Duration` 换算成秒。
    ///
    /// - Parameter duration: 时长。
    /// - Returns: 秒数（`Duration` 的分量是「秒 + 阿秒」，1 阿秒 = 1e-18 秒）。
    static func seconds(from duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
