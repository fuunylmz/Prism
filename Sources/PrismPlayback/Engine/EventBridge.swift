import Foundation
import PrismCore

/// Combine / 引擎回调 → ``AsyncStream`` 的桥。
///
/// ## 为什么需要它
///
/// 引擎用 Combine `@Published` 发状态，我们的契约要求 `AsyncStream<PlaybackEvent>`。
/// **不要**用 `sink` + `AnyCancellable` 手写订阅：`AnyCancellable` 不是 `Sendable`，
/// 存进 `@MainActor` 类型之外的地方在 Swift 6 严格并发下会报错
/// （见 `docs/ARCHITECTURE.md` §3.2）。适配器改用 `player.$state.values`
/// （`AsyncPublisher`）在 `@MainActor` 上 `for await`，把结果喂给这个桥。
///
/// 这个类型只负责「事件出口」：它不引用任何引擎类型，因此可以安全地跨 actor 传递。
/// 事件流是**单消费者**的；``finish()`` 之后消费者会正常结束 `for await`。
public final class PlaybackEventBridge: Sendable {
    /// 对外的事件流。
    public let events: AsyncStream<PlaybackEvent>

    private let continuation: AsyncStream<PlaybackEvent>.Continuation

    /// 创建桥。
    ///
    /// - Parameter bufferingPolicy: 背压策略。默认保留最新 256 条：
    ///   UI 卡顿时宁可丢旧位置事件，也不要让引擎侧阻塞或无限积压。
    public init(
        bufferingPolicy: AsyncStream<PlaybackEvent>.Continuation.BufferingPolicy = .bufferingNewest(256)
    ) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: PlaybackEvent.self,
            bufferingPolicy: bufferingPolicy
        )
        self.events = stream
        self.continuation = continuation
    }

    /// 发一条事件。流已结束时是安全的空操作。
    ///
    /// - Parameter event: 事件。
    public func yield(_ event: PlaybackEvent) {
        continuation.yield(event)
    }

    /// 结束事件流（适配器销毁 / 显式关闭时调用）。可重复调用。
    public func finish() {
        continuation.finish()
    }
}

// MARK: - 位置闸门

/// 位置事件的闸门：负责「至少 4Hz 的去重」与「切音轨期间冻结进度」（坑 2）。
///
/// 引擎在切音轨时会重建管线，`clock.sourceTime` 会从 9.073 掉到 0.000、约 86ms 后再弹回
/// （实测见 `docs/research/playback-spike-results.md` §3）。若进度条直绑时钟，就会闪一下 0。
///
/// 处理方式：
/// - 切轨前 ``freeze()``：期间 ``accept(position:duration:force:)`` 一律返回 `nil`，
///   即**不发** ``PlaybackEvent/positionChanged(_:duration:)``，也不覆盖最后一次有效位置；
/// - 重建结束（引擎回到 `.playing` / `.paused`，或兜底超时）时 ``thaw(at:)``：
///   用**重建后**的真实位置补发一次，让 UI 从正确位置继续。
struct PlaybackPositionGate: Sendable {
    /// 是否处于冻结（切轨重建）中。
    private(set) var isFrozen = false

    /// 最后一次有效位置。
    private(set) var position: Ticks = .zero

    /// 最后一次已知时长。
    private(set) var duration: Ticks = .zero

    /// 是否已经发过至少一条位置事件。
    private(set) var hasEmitted = false

    /// 创建闸门。
    init() {}

    /// 更新时长（冻结期间也允许更新：时长在重建中不会变，但别把它丢了）。
    ///
    /// - Parameter duration: 新的总时长。
    mutating func setDuration(_ duration: Ticks) {
        self.duration = duration
    }

    /// 冻结：进入切轨重建。
    mutating func freeze() {
        isFrozen = true
    }

    /// 解冻并补发一次位置事件。
    ///
    /// - Parameter clockPosition: 解冻瞬间的引擎时钟读数。
    /// - Returns: 要发出去的 ``PlaybackEvent/positionChanged(_:duration:)``。
    ///
    /// - Important: 取 `max(时钟, 冻结前最后有效位置)`。实测引擎刚回到 `.playing` 的
    ///   ~50ms 里 `clock.currentTime` 仍是 0（`t+0.101s playing / 0.000`，
    ///   `t+0.155s` 才回到 9.072），直接用时钟会把 0 发给 UI —— 那正是坑 2 要避免的闪烁。
    mutating func thaw(clockPosition: Ticks) -> PlaybackEvent {
        isFrozen = false
        let resolved = max(clockPosition, position)
        position = resolved
        hasEmitted = true
        return .positionChanged(resolved, duration: duration)
    }

    /// 接受一次时钟读数。
    ///
    /// - Parameters:
    ///   - position: 当前位置。
    ///   - duration: 当前总时长。
    ///   - force: 强制发一条（seek 之后用，即使位置没变也要让 UI 对齐）。
    /// - Returns: 要发出去的事件；冻结中或位置/时长都没变时返回 `nil`。
    mutating func accept(position newPosition: Ticks, duration newDuration: Ticks, force: Bool = false) -> PlaybackEvent? {
        guard !isFrozen else { return nil }
        let changed = !hasEmitted || newPosition != position || newDuration != duration
        position = newPosition
        duration = newDuration
        hasEmitted = true
        guard changed || force else { return nil }
        return .positionChanged(newPosition, duration: newDuration)
    }

    /// 重置（新的 load / stop）。
    mutating func reset() {
        isFrozen = false
        position = .zero
        duration = .zero
        hasEmitted = false
    }
}

// MARK: - 字幕时间轴闸门

/// 字幕 cue 的持有者 + 延迟偏移施加者（坑 4）。
///
/// AetherEngine 的 `setSoftwareSubtitleDelay` **只作用于 software PiP 合成**，
/// 不会改变 `$subtitleCues` 的时间轴（实测见 `docs/research/playback-spike-results.md` §2）。
/// Prism 在窗口内自绘字幕，所以偏移必须由我们自己维护：
/// 保存引擎给的最新 cue，每次发 ``PlaybackEvent/subtitleCues(_:)`` 前对时间轴施加当前偏移。
struct SubtitleTimelineGate: Sendable {
    /// 当前延迟（秒，正 = 延后）。
    private(set) var delay: Double = 0

    /// 引擎给的最新一批 cue（**未**施加偏移的原始媒体时间轴）。
    private(set) var cues: [SubtitleCue] = []

    /// 创建闸门。
    init() {}

    /// 设置延迟。
    ///
    /// - Parameter seconds: 秒；非有限值忽略（保持原值）。
    /// - Returns: 是否真的变了（没变就不必重发 cue）。
    @discardableResult
    mutating func setDelay(_ seconds: Double) -> Bool {
        guard seconds.isFinite, seconds != delay else { return false }
        delay = seconds
        return true
    }

    /// 换一批 cue。
    ///
    /// - Parameter cues: 引擎最新发布的 cue（原始时间轴）。
    mutating func update(cues: [SubtitleCue]) {
        self.cues = cues
    }

    /// 施加当前延迟后的 cue（被完全推到 0 之前的 cue 会被丢掉）。
    var shiftedCues: [SubtitleCue] {
        guard delay != 0 else { return cues }
        return cues.compactMap { $0.shifted(by: delay) }
    }

    /// 重置（新的 load / stop）。
    mutating func reset() {
        delay = 0
        cues = []
    }
}
