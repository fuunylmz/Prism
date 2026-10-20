import EmbyAPI
import Foundation
import PrismCore

/// 把播放进度同步到 Emby 服务器。
///
/// 这是 T3.4「进度上报与续播」的执行者：引擎只负责**告诉我们播到哪了**，
/// 由本类型决定「什么时候、以什么字段」发请求。它不 import 任何播放内核
/// （`AetherEngine` 只出现在 `Engine/`），因此可以脱离播放器单测。
///
/// ## 三个端点
///
/// | 时机 | 端点 | 请求体 |
/// |---|---|---|
/// | 开始播放 | `POST /Sessions/Playing` | ``PlaybackProgressReport``（30 字段） |
/// | 播放中 / 交互 | `POST /Sessions/Playing/Progress` | ``PlaybackProgressReport``（30 字段） |
/// | 停止播放 | `POST /Sessions/Playing/Stopped` | ``PlaybackStopReport``（**14 字段**） |
///
/// - ✅ 来源：<https://dev.emby.media/doc/restapi/Playback-Check-ins.html>
///
/// - Important: **停止上报只有 14 个字段**。官方 Playback-Check-ins 文档写
///   「The contents of the request are identical to the playback start message」，
///   这句是**错的**：`PlaybackStopInfo` 的 schema 里没有 `PlayMethod`、`IsPaused`、
///   `CanSeek`、`VolumeLevel`、`AudioStreamIndex`、`SubtitleStreamIndex`、
///   `RunTimeTicks`、`EventName` 等字段。
///   - ✅ 反证：<https://dev.emby.media/reference/RestAPI/PlaystateService/postSessionsPlayingStopped.html>
///     的 Definitions 段只有 14 项（2026-10-21 逐项核对）。
///   - 本类型因此**在类型层面**就用 ``PlaybackStopReport`` 构造停止请求，
///     不可能误用 30 字段的结构。回归测试见 `Tests/PrismPlaybackTests/ProgressReporterTests.swift`。
///
/// ## 上报节奏
///
/// 本类型是**被推着走**的（pull-driven），不自己起定时器：
/// 引擎以约 4Hz 调 ``report(position:isPaused:)``，``ProgressThrottler`` 负责把
/// 它压到「10 秒一次 + 交互立即」。
///
/// 这样做有两个理由：
/// 1. 不用 `Task.sleep`，因此可以用 ``PrismCore/FixedClock`` 之类注入时钟把 10 秒走完，
///    测试不需要真的等 10 秒；
/// 2. 暂停时引擎不再推进位置，也就不会再有定时上报——这正好符合预期，
///    而内部定时器会持续上报同一个位置。
///
/// 引擎侧只要在每次位置回调时调一次 `report` 即可：
///
/// ```swift
/// let reporter = ProgressReporter(
///     client: client,
///     userId: user.id,
///     itemId: item.id,
///     method: PlayMethod.directPlay.rawValue,   // TODO: 待 Negotiation 的 PlaybackMethod 落地
///     mediaSourceId: source.id,
///     playSessionId: info.playSessionId
/// )
/// await reporter.start(position: resumeAt)
/// // …引擎每帧回调…
/// await reporter.report(position: clock.sourceTime, isPaused: false)
/// // 用户暂停
/// await reporter.report(position: clock.sourceTime, isPaused: true)
/// // 退出播放器
/// await reporter.stop(position: clock.sourceTime)
/// ```
///
/// ## 失败处理
///
/// 上报失败**不影响播放**：请求照发，失败时把该条塞进 ``PendingProgressQueue``，
/// 下一次成功上报时顺带补发。队列只存内存、上限 50 条，进程被杀就丢（v1.1 换 GRDB）。
public actor ProgressReporter {
    /// 当前用户 id。
    ///
    /// 鉴权头里已带 `UserId=`，三个上报端点的路径也不含用户 id，因此本属性
    /// **不参与请求构造**；保留它是为了日志与上层排障（谁在看什么）。
    public nonisolated let userId: String

    /// 条目 id。
    public nonisolated let itemId: String

    /// 媒体源 id（多版本条目靠它区分）。
    public nonisolated let mediaSourceId: String

    /// 播放会话 id（`PlaybackInfo` 返回的 `PlaySessionId`，必须原样透传）。
    public nonisolated let playSessionId: String?

    /// 播放方式（协商层的结论）。
    public nonisolated let method: PlaybackMethod

    /// 播放方式对应的 Emby `PlayMethod` 取值，用于填上报体。
    public nonisolated let playMethod: PlayMethod

    /// 定时上报间隔。
    public nonisolated let interval: Duration

    /// 网络客户端。
    private let client: EmbyClient

    /// 注入的时钟，测试用它把 10 秒「快进」过去。
    private let clock: any ClockProviding

    /// 日志。
    private let logger: any Logging

    /// 离线补报队列。
    private let queue: PendingProgressQueue

    /// 节流与去重。
    private var throttler: ProgressThrottler

    /// seek 判定容差。
    private let seekTolerance: Ticks

    /// 上一次观测到的位置（**每次** `report` 都更新，无论是否真的发出请求）。
    private var lastObservedPosition: Ticks?

    /// 上一次观测的时刻。
    private var lastObservedAt: Date?

    /// 上一次观测到的暂停状态。
    private var lastObservedPaused = true

    /// ``start(position:)`` 是否已成功走过。
    public private(set) var isStarted = false

    /// 创建上报器。
    ///
    /// - Parameters:
    ///   - client: Emby 客户端（需已 ``EmbyAPI/EmbyClient/setAccessToken(_:)``）。
    ///   - userId: 当前用户 id（仅用于日志）。
    ///   - itemId: 条目 id。
    ///   - method: 播放方式，由协商层（``PlaybackMethod``）给出。
    ///     进度层不重复定义这个类型，只把它映射成 Emby 的 ``EmbyAPI/PlayMethod``。
    ///   - mediaSourceId: 媒体源 id。
    ///   - playSessionId: 播放会话 id。
    ///   - interval: 定时上报间隔，默认 10 秒（Emby 官方建议值）。
    ///   - clock: 时钟，默认 ``PrismCore/SystemClock``；测试注入可变时钟。
    ///   - logger: 日志，默认 `OSLogger(category: "progress")`。
    ///   - queueCapacity: 离线队列容量，默认 ``PendingProgressQueue/defaultCapacity``。
    ///   - seekTolerance: seek 判定容差，默认 2 秒。位置相对「上次位置 + 已流逝时间」
    ///     的偏移超过它时视为 seek，立即上报。
    public init(
        client: EmbyClient,
        userId: String,
        itemId: String,
        method: PlaybackMethod,
        mediaSourceId: String,
        playSessionId: String?,
        interval: Duration = .seconds(10),
        clock: any ClockProviding = SystemClock(),
        logger: any Logging = OSLogger(category: "progress"),
        queueCapacity: Int = PendingProgressQueue.defaultCapacity,
        seekTolerance: Ticks = Ticks(seconds: 2)
    ) {
        self.client = client
        self.userId = userId
        self.itemId = itemId
        self.mediaSourceId = mediaSourceId
        self.playSessionId = playSessionId
        self.method = method
        self.playMethod = PlayMethod(rawValue: method.embyPlayMethod)
        self.interval = interval
        self.clock = clock
        self.logger = logger
        self.seekTolerance = seekTolerance
        self.throttler = ProgressThrottler(interval: interval)
        self.queue = PendingProgressQueue(capacity: queueCapacity) { report in
            try await ProgressReporter.transmit(report, client: client)
        }
    }

    // MARK: - 生命周期

    /// 开始播放：`POST /Sessions/Playing`。
    ///
    /// 同时把节流窗口对齐到此刻，因此下一次定时上报发生在 ``interval`` 之后。
    ///
    /// - Parameter position: 起播位置（续播时是 ``ResumePolicy/resumePosition(for:)`` 的返回值）。
    public func start(position: Ticks) async {
        let now = clock.now
        var report = PlaybackProgressReport(
            itemId: itemId,
            playSessionId: playSessionId,
            mediaSourceId: mediaSourceId,
            positionTicks: position
        )
        report.playMethod = playMethod
        report.isPaused = false
        // EventName 留空：它描述的是「为什么上报进度」，开始播放不属于任何进度事件。

        isStarted = true
        lastObservedPosition = position
        lastObservedAt = now
        lastObservedPaused = false
        throttler.reset()
        throttler.markReported(position: position, at: now)

        do {
            try await ProgressReporter.transmit(.start(report), client: client)
            await drainIfNeeded()
        } catch {
            logger.warning(
                "开始播放上报失败，已入队待补报",
                metadata: ["itemId": itemId, "error": String(describing: error)]
            )
            await queue.enqueue(.start(report))
        }
    }

    /// 播放中：`POST /Sessions/Playing/Progress`，由 ``ProgressThrottler`` 决定是否真的发出。
    ///
    /// 引擎可以放心地以任意频率（建议 4Hz）调用本方法：
    /// - 距上次上报不足 ``interval``（默认 10 秒）→ 静默跳过；
    /// - 位置变化不足 1 秒 → 静默跳过；
    /// - 暂停状态翻转（暂停 / 恢复）或检测到 seek → **立即**发出，不等 10 秒。
    ///
    /// - Parameters:
    ///   - position: 当前位置。
    ///   - isPaused: 是否处于暂停状态。
    public func report(position: Ticks, isPaused: Bool) async {
        let now = clock.now
        let classification = classify(position: position, isPaused: isPaused, now: now)

        // 先更新观测值再判定是否发送：即便本次被节流，seek 判定的基准也要往前走。
        lastObservedPosition = position
        lastObservedAt = now
        lastObservedPaused = isPaused

        guard throttler.shouldReport(
            position: position,
            isInteraction: classification.isInteraction,
            now: now
        ) else { return }

        await sendProgress(position: position, isPaused: isPaused, event: classification.event)
    }

    /// 用户交互：立即上报（暂停 / 恢复 / 切音轨 / 切字幕 / 改倍速…）。
    ///
    /// 暂停与恢复也可以走 ``report(position:isPaused:)``（它自己会检测状态翻转），
    /// 但**切音轨 / 切字幕**这类交互位置没变、暂停状态也没变，必须由调用方显式告知，
    /// 否则会被「位置没动」的去重规则吞掉。
    ///
    /// - Parameters:
    ///   - event: 交互类型，取 ``EmbyAPI/ProgressEvent`` 的常量
    ///     （`.pause` / `.unpause` / `.audioTrackChange` / `.subtitleTrackChange` …）。
    ///   - position: 当前位置。
    ///   - isPaused: 当前是否暂停。
    public func reportInteraction(_ event: ProgressEvent, position: Ticks, isPaused: Bool) async {
        let now = clock.now
        lastObservedPosition = position
        lastObservedAt = now
        lastObservedPaused = isPaused
        _ = throttler.shouldReport(position: position, isInteraction: true, now: now)
        await sendProgress(position: position, isPaused: isPaused, event: event)
    }

    /// 停止播放：`POST /Sessions/Playing/Stopped`（**14 字段**，不含 `PlayMethod` / `IsPaused`）。
    ///
    /// - Parameter position: 停止时的位置，服务端靠它写最终进度。
    public func stop(position: Ticks) async {
        let report = PlaybackStopReport(
            itemId: itemId,
            playSessionId: playSessionId,
            mediaSourceId: mediaSourceId,
            positionTicks: position
        )
        isStarted = false
        throttler.reset()

        do {
            try await ProgressReporter.transmit(.stop(report), client: client)
            await drainIfNeeded()
        } catch {
            logger.warning(
                "停止播放上报失败，已入队待补报",
                metadata: ["itemId": itemId, "error": String(describing: error)]
            )
            await queue.enqueue(.stop(report))
        }
    }

    // MARK: - 离线补报

    /// 补发队列里积压的上报；启动时调用一次即可。
    ///
    /// - Note: 与 `ARCHITECTURE §4` 里 `ProgressReporter.flushPending()` 的语义等价，
    ///   名字按工单要求取作 `drain()`。
    public func drain() async {
        let sent = await queue.drain()
        if sent > 0 {
            logger.info("补报完成", metadata: ["count": String(sent), "itemId": itemId])
        }
    }

    /// 队列里还有多少条待补报（诊断与测试用）。
    ///
    /// - Returns: 条数。
    public func pendingReportCount() async -> Int {
        await queue.count
    }

    /// ``drain()`` 的别名。
    ///
    /// `ARCHITECTURE §4` 的冻结契约把这个方法写作 `flushPending()`，
    /// 而 T3.4 工单要求叫 `drain()`。两个名字都保留，语义完全一致，
    /// 这样按契约写的上层代码与按工单写的调用点都不需要改。
    public func flushPending() async {
        await drain()
    }

    // MARK: - 内部

    /// 一次上报的分类结果。
    private struct Classification {
        /// 要写进 `EventName` 的事件。
        let event: ProgressEvent
        /// 是否属于用户交互（交互事件绕过节流与去重）。
        let isInteraction: Bool
    }

    /// 判定本次 `report` 属于哪种事件。
    ///
    /// - Parameters:
    ///   - position: 当前位置。
    ///   - isPaused: 当前暂停状态。
    ///   - now: 当前时刻。
    /// - Returns: 事件类型与是否为交互。
    private func classify(position: Ticks, isPaused: Bool, now: Date) -> Classification {
        // 1. 暂停状态翻转 —— 官方把它归为交互，立即上报。
        if isPaused != lastObservedPaused {
            return Classification(event: isPaused ? .pause : .unpause, isInteraction: true)
        }

        // 2. seek 检测：位置跳变远超「上次位置 + 已经过的时间」。
        //    阈值加上了 elapsed，是为了不把「停了很久之后位置正常前进了很久」误判成 seek。
        if let lastPosition = lastObservedPosition, let lastAt = lastObservedAt {
            let elapsed = max(0, now.timeIntervalSince(lastAt))
            let moved = abs((position - lastPosition).seconds)
            if moved > elapsed + seekTolerance.seconds {
                // seek 的 EventName 仍是 TimeUpdate（官方建议），只是不等 10 秒窗口。
                return Classification(event: .timeUpdate, isInteraction: true)
            }
        }

        return Classification(event: .timeUpdate, isInteraction: false)
    }

    /// 发出一次进度上报；失败则入队。
    ///
    /// - Parameters:
    ///   - position: 当前位置。
    ///   - isPaused: 是否暂停。
    ///   - event: `EventName`。
    private func sendProgress(position: Ticks, isPaused: Bool, event: ProgressEvent) async {
        var report = PlaybackProgressReport(
            itemId: itemId,
            playSessionId: playSessionId,
            mediaSourceId: mediaSourceId,
            positionTicks: position
        )
        report.playMethod = playMethod
        report.isPaused = isPaused
        report.eventName = event

        do {
            try await ProgressReporter.transmit(.progress(report), client: client)
            await drainIfNeeded()
        } catch {
            logger.warning(
                "进度上报失败，已入队待补报",
                metadata: ["itemId": itemId, "event": event.rawValue, "error": String(describing: error)]
            )
            await queue.enqueue(.progress(report))
        }
    }

    /// 队列非空时顺带补报（「下次成功时批量补报」）。
    private func drainIfNeeded() async {
        guard await !queue.isEmpty else { return }
        await drain()
    }

    /// 把一条上报真正发出去。
    ///
    /// - Parameters:
    ///   - report: 待发送的上报。
    ///   - client: Emby 客户端。
    /// - Throws: ``PrismCore/EmbyError``。
    private static func transmit(_ report: PendingProgressReport, client: EmbyClient) async throws {
        switch report {
        case let .start(payload):
            try await client.send(PlayingStartEndpoint(report: payload))
        case let .progress(payload):
            try await client.send(PlayingProgressEndpoint(report: payload))
        case let .stop(payload):
            // 注意：这里刻意用 PlaybackStopReport（14 字段），不要换成 30 字段的结构。
            try await client.send(PlayingStoppedEndpoint(report: payload))
        }
    }
}

// MARK: - 命名冲突的逃生口

/// ``ProgressReporter`` 的别名，供同时 `import Foundation` 的调用方使用。
///
/// macOS 27 的 Foundation 新增了一个同名类 `Foundation.ProgressReporter`
/// （进度管理 API）。任何同时 `import Foundation` 与 `import PrismPlayback` 的文件
/// 里裸写 `ProgressReporter` 都会报
/// `'ProgressReporter' is ambiguous for type lookup`，且**无法**用
/// `PrismPlayback.ProgressReporter` 消歧——本模块内还有一个同名的
/// ``PrismPlayback`` 枚举会遮蔽模块名。
///
/// 因此需要显式引用时，请用这个别名：
///
/// ```swift
/// let reporter: PlaybackProgressReporter = ...
/// ```
public typealias PlaybackProgressReporter = ProgressReporter
