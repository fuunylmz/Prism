import Foundation
import Observation
import PrismCore
import PrismPlayback
import SwiftUI

// MARK: - 视图模型

/// 播放器页面的视图模型。
///
/// 职责边界：
/// - **只依赖 ``PrismPlayback/PlaybackEngine`` 协议**，不认识任何具体引擎
///   （AetherEngine / mpv / 未来的 Plan B）；
/// - 消费 `engine.events`（`AsyncStream<PlaybackEvent>`）并把事件收敛成 UI 需要的
///   少量状态：位置、时长、缓冲、轨道、播放状态；
/// - 处理 `docs/ARCHITECTURE.md` §3.5 里两个必须由 UI 兜住的引擎行为
///   （坑 1：`duration` 起播瞬间为 0；坑 2：切音轨时 `sourceTime` 归零）。
///
/// **所有属性都在 `@MainActor` 上**，视图可直接读；`await` 只出现在调用引擎的地方。
///
/// ```swift
/// let model = PlayerViewModel()
/// await model.attach(engine: engine)
/// await model.togglePlayPause()
/// ```
@MainActor
@Observable
public final class PlayerViewModel {
    // MARK: - 播放状态

    /// 引擎上报的播放状态。
    public private(set) var state: PlaybackState = .idle

    /// 当前播放位置。
    ///
    /// **坑 2**：`.loading` 期间（切音轨会触发约 143ms 的重建）这个值被冻结，
    /// 不会跟随引擎的 `sourceTime` 归零，因此进度条不会闪 0。
    public private(set) var position: Ticks = .zero

    /// 总时长。
    ///
    /// **坑 1**：初始为 0，只有收到 `.durationChanged` 才更新。在它到来之前
    /// ``hasDuration`` 为 `false`，进度条显示不确定态而不是「00:00」。
    public private(set) var duration: Ticks = .zero

    /// 已缓冲到的位置。
    public private(set) var buffered: Ticks = .zero

    /// 音轨列表（引擎上报，顺序即菜单顺序）。
    public private(set) var audioTracks: [TrackInfo] = []

    /// 字幕轨列表；空数组表示「该视频没有字幕」。
    public private(set) var subtitleTracks: [TrackInfo] = []

    /// 当前要显示的字幕 cue。
    ///
    /// 时间轴**已经**由适配器施加了字幕延迟（§3.5 坑 4），UI 直接按
    /// `start...end` 与 ``position`` 比较即可，不需要再偏移一次。
    /// v1.0 的字幕渲染归 T3.6；本工单只负责把 cue 收下来并保证它随位置变化而刷新。
    public private(set) var subtitleCues: [SubtitleCue] = []

    /// 控制条是否可见（3 秒无操作自动隐藏）。
    public var isControlsVisible: Bool = true

    // MARK: - 用户可调状态

    /// 音量（0...1）。引擎协议没有 getter，因此由视图模型自己记。
    public private(set) var volume: Double = 1

    /// 是否静音。
    public private(set) var isMuted = false

    /// 播放倍速。
    public private(set) var rate: Double = 1

    /// 字幕延迟（秒）。正值表示字幕**延后**出现。
    public private(set) var subtitleDelay: Double = 0

    /// 当前选中的音轨索引（引擎的 track index）；`nil` 表示未知。
    public private(set) var selectedAudioIndex: Int?

    /// 当前选中的字幕轨索引；`nil` 表示字幕关闭。
    public private(set) var selectedSubtitleIndex: Int?

    /// 关闭字幕前记住的轨道，用于 `S` 再次按下时恢复。
    private var lastSubtitleIndex: Int?

    // MARK: - 派生状态

    /// 是否已经拿到可信的时长（坑 1 的开关）。
    public private(set) var hasDuration = false

    /// 是否正在拖拽进度条。拖拽期间忽略引擎的位置更新。
    public private(set) var isScrubbing = false

    /// 缓冲超过 1 秒后才显示的中央转圈（避免每次微缓冲都闪一下）。
    public private(set) var isBufferingVisible = false

    /// 是否正在播放。
    public var isPlaying: Bool {
        state == .playing
    }

    /// 是否处于「起播加载」（显示菊花 + 「正在准备播放…」）。
    public var isLoading: Bool {
        state == .loading
    }

    /// 是否处于缓冲。
    public var isBuffering: Bool {
        state == .buffering
    }

    /// 播放失败时的失败原因；未失败为 `nil`。
    public var failure: PlaybackFailure? {
        state.failure
    }

    /// 是否处于失败态。
    public var hasFailed: Bool {
        failure != nil
    }

    /// 播放进度（0...1）；时长未知时为 0。
    public var progress: Double {
        guard hasDuration else { return 0 }
        let raw = position.seconds / duration.seconds
        guard raw.isFinite else { return 0 }
        return min(max(raw, 0), 1)
    }

    /// 缓冲进度（0...1）。
    public var bufferedProgress: Double {
        guard hasDuration else { return 0 }
        let raw = buffered.seconds / duration.seconds
        guard raw.isFinite else { return 0 }
        return min(max(raw, 0), 1)
    }

    /// 字幕延迟的展示文案，例如 `+0.3s` / `0.0s` / `-0.1s`。
    public var subtitleDelayText: String {
        let sign = subtitleDelay > 0 ? "+" : ""
        return String(format: "\(sign)%.1fs", subtitleDelay)
    }

    /// 当前音轨；没有音轨时为 `nil`。
    public var currentAudioTrack: TrackInfo? {
        guard let selectedAudioIndex else { return audioTracks.first }
        return audioTracks.first { $0.playerIndex == selectedAudioIndex } ?? audioTracks.first
    }

    /// 当前字幕轨；字幕关闭时为 `nil`。
    public var currentSubtitleTrack: TrackInfo? {
        guard let selectedSubtitleIndex else { return nil }
        return subtitleTracks.first { $0.playerIndex == selectedSubtitleIndex }
    }

    /// 音轨菜单的展示项（已排版成「语言 · 声道 · 编码」）。
    ///
    /// 视图层因此完全不认识 ``PrismPlayback/TrackInfo``，`#Preview` 也不需要构造引擎对象。
    public var audioTrackItems: [PlayerTrack] {
        audioTracks.map { PlayerTrack(track: $0) }
    }

    /// 字幕菜单的展示项（已排版成「语言 · 类型 · 内嵌/外挂」）。
    public var subtitleTrackItems: [PlayerTrack] {
        subtitleTracks.map { PlayerTrack(track: $0) }
    }

    // MARK: - 私有状态

    /// 引擎。
    private var engine: (any PlaybackEngine)?

    /// 引擎的渲染面；`nil` 表示还没有 attach。
    ///
    /// 引擎给的是 `AnyView`（内部已经绑好图层），播放器直接把它铺满窗口即可。
    public private(set) var renderView: AnyView?

    /// 事件消费任务。
    private var eventTask: Task<Void, Never>?

    /// 自动隐藏任务。
    private var autoHideTask: Task<Void, Never>?

    /// 缓冲转圈延迟任务。
    private var bufferingTask: Task<Void, Never>?

    /// 控制条是否被「钉住」（菜单弹层展开时为 `true`，此时不自动隐藏）。
    private var isControlsPinned = false

    /// 上一次用户操作的时间，用于节流鼠标移动事件。
    private var lastActivity = Date.distantPast

    /// 进入 `.loading` 前最后一次可信的位置（坑 2 的「保留值」）。
    private var stablePosition: Ticks = .zero

    /// 是否因为 `.loading` 而冻结位置。
    private var isPositionFrozen = false

    /// 离开 `.loading` 后的短暂保护窗口：引擎时钟可能在 `.playing` 里还归零几十毫秒。
    private var resumeGuardDeadline: Date?

    /// 控制条自动隐藏延时（秒）。
    public static let controlsAutoHideDelay: Double = 3

    /// 缓冲转圈出现阈值（秒）。
    public static let bufferingIndicatorDelay: Double = 1

    /// 创建视图模型。
    public init() {}

    /// 预览 / 测试专用：直接注入一份状态，不启动任何任务。
    ///
    /// 公开 API 只能通过 `attach(engine:)` + 事件流得到状态，而 `#Preview` 需要
    /// 「暂停」「错误」「控制条已隐藏」这类瞬时快照。这个初始化器就是那个后门，
    /// **只在 `Player/` 内部可见**（`internal`），不影响对外契约。
    ///
    /// - Parameters:
    ///   - previewState: 初始播放状态。
    ///   - position: 播放位置。
    ///   - duration: 总时长；大于 0 时视为「时长已就绪」。
    ///   - buffered: 缓冲位置。
    ///   - audioTracks: 音轨列表。
    ///   - subtitleTracks: 字幕轨列表。
    ///   - selectedAudioIndex: 当前音轨索引。
    ///   - selectedSubtitleIndex: 当前字幕轨索引。
    ///   - volume: 音量。
    ///   - isMuted: 是否静音。
    ///   - rate: 倍速。
    ///   - subtitleDelay: 字幕延迟。
    ///   - isControlsVisible: 控制条是否可见。
    ///   - isBufferingVisible: 缓冲转圈是否可见。
    ///   - renderView: 引擎渲染面（预览一般传 `nil`）。
    init(
        previewState: PlaybackState,
        position: Ticks = .zero,
        duration: Ticks = .zero,
        buffered: Ticks = .zero,
        audioTracks: [TrackInfo] = [],
        subtitleTracks: [TrackInfo] = [],
        selectedAudioIndex: Int? = nil,
        selectedSubtitleIndex: Int? = nil,
        volume: Double = 1,
        isMuted: Bool = false,
        rate: Double = 1,
        subtitleDelay: Double = 0,
        isControlsVisible: Bool = true,
        isBufferingVisible: Bool = false,
        renderView: AnyView? = nil
    ) {
        self.state = previewState
        self.position = position
        self.duration = duration
        self.buffered = buffered
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
        self.selectedAudioIndex = selectedAudioIndex
        self.selectedSubtitleIndex = selectedSubtitleIndex
        self.volume = volume
        self.isMuted = isMuted
        self.rate = rate
        self.subtitleDelay = subtitleDelay
        self.isControlsVisible = isControlsVisible
        self.isBufferingVisible = isBufferingVisible
        self.renderView = renderView
        self.hasDuration = duration.rawValue > 0
        if let selectedSubtitleIndex {
            self.lastSubtitleIndex = selectedSubtitleIndex
        }
    }

    /// 起播前预置时长（来自协商结果的 `PlaybackPlan.duration`）。
    ///
    /// 坑 1 的**优化**而不是替代：协商层已经知道片长时，先把进度条画出来，
    /// 用户就不会在起播的 61ms 里看到不确定态；引擎的 `.durationChanged` 仍然会
    /// 覆盖它（以引擎为准）。
    ///
    /// - Parameter value: 片长；非正值会被忽略。
    public func primeDuration(_ value: Ticks) {
        guard value.rawValue > 0, !hasDuration else { return }
        duration = value
        hasDuration = true
    }

    // MARK: - 生命周期

    /// 绑定引擎并开始消费事件流。
    ///
    /// 可以重复调用（换集时换引擎）；旧的事件任务会先被取消，避免两个引擎的事件
    /// 同时写进同一个视图模型。
    ///
    /// - Parameter engine: 实现了 ``PrismPlayback/PlaybackEngine`` 的引擎。
    public func attach(engine: any PlaybackEngine) async {
        detach()
        self.engine = engine
        renderView = engine.renderView

        let events = engine.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.apply(event)
            }
        }
    }

    /// 解除绑定并取消事件消费。
    ///
    /// 页面关闭时调用；引擎本身的生命周期由调用方管理（引擎协议有 `stop()`）。
    public func detach() {
        onPositionUpdate = nil
        onPlaybackStateChange = nil
        eventTask?.cancel()
        eventTask = nil
        autoHideTask?.cancel()
        autoHideTask = nil
        bufferingTask?.cancel()
        bufferingTask = nil
        engine = nil
        renderView = nil
    }

    // MARK: - 外部失败

    /// 把「还没进引擎就失败」的原因告诉界面。
    ///
    /// 协商 / 建会话失败时引擎根本没 attach，`renderView` 为空，页面只会显示
    /// 「等待播放引擎…」。这条把失败转成 `.failed` 状态，用户才能看到原因并重试。
    ///
    /// - Parameter message: 面向用户的失败说明。
    public func reportPreparationFailure(_ message: String) {
        handleStateChange(.failed(PlaybackFailure(kind: .load, message: message, isRecoverable: true)))
    }

    // MARK: - 事件

    /// 消费一条播放事件。
    ///
    /// - Parameter event: 引擎事件。
    /// 位置观察回调：每当播放位置推进时触发，供**进度上报**使用。
    ///
    /// 为什么不直接让编排器消费 `engine.events`：那个 `AsyncStream` 是**单消费者**的，
    /// 已被本视图模型占用（见 `PlaybackEngine.events` 的文档）。所以由这里做一次转发，
    /// 而不是让两个地方抢同一个流。
    ///
    /// - Note: 在 `@MainActor` 上调用；实现里不要做重活（上报器内部会节流）。
    public var onPositionUpdate: ((Ticks, Bool) -> Void)?

    /// 播放状态变化回调（暂停 / 恢复 / 播完 / 失败）。
    ///
    /// 为什么需要单独一条：暂停之后引擎位置不再变化，`.positionChanged` 不会再发，
    /// 只靠位置回调无法把「用户暂停了」告诉服务器。缺了它，服务器会一直认为
    /// 你还在播放，续播点被推到片子中间。
    public var onPlaybackStateChange: ((PlaybackState) -> Void)?

    private func apply(_ event: PlaybackEvent) {
        switch event {
        case let .stateChanged(newState):
            handleStateChange(newState)

        case let .positionChanged(newPosition, engineDuration):
            handlePosition(newPosition, engineDuration: engineDuration)
            onPositionUpdate?(position, state == .paused)

        case let .durationChanged(newDuration):
            // 坑 1：只认这条事件。0 值视为「还没准备好」，不覆盖已有值。
            guard newDuration.rawValue > 0 else { return }
            duration = newDuration
            hasDuration = true

        case let .bufferChanged(fraction):
            guard hasDuration else { return }
            let clamped = min(max(fraction, 0), 1)
            buffered = Ticks(seconds: duration.seconds * clamped)

        case let .tracksChanged(audio, subtitle):
            // 按 stream id 去重：同 id 必然是同一条流。引擎在重建管线 / 切换
            // 音轨后会重发整张表，偶发把同一条流报两次；不去重的话菜单里会
            // 出现两行完全一样、无法区分的条目。
            audioTracks = Self.uniqueTracks(audio)
            subtitleTracks = Self.uniqueTracks(subtitle)
            reconcileTrackSelection()

        case let .subtitleCues(cues):
            subtitleCues = cues

        case .ended:
            handleStateChange(.ended)

        case let .failed(failure):
            handleStateChange(.failed(failure))
        }
    }

    /// 处理状态迁移。
    ///
    /// **坑 2 的核心**：进入 `.loading` 时记下最后一个可信位置并冻结进度；
    /// 离开 `.loading` 后给引擎一个短暂的「时钟追赶」窗口，期间忽略向后的跳变。
    ///
    /// - Parameter newState: 新状态。
    private func handleStateChange(_ newState: PlaybackState) {
        let wasLoading = state == .loading
        state = newState

        switch newState {
        case .loading:
            stablePosition = position
            isPositionFrozen = true
            resumeGuardDeadline = nil
            cancelAutoHide()

        case .playing:
            if wasLoading {
                isPositionFrozen = false
                resumeGuardDeadline = Date().addingTimeInterval(0.35)
                // 重建期间引擎可能已经把位置回退到 0，先把 UI 保持在稳定值上。
                position = stablePosition
            }
            isBufferingVisible = false
            bufferingTask?.cancel()
            scheduleAutoHide()

        case .paused:
            isPositionFrozen = false
            isBufferingVisible = false
            bufferingTask?.cancel()
            showControls()

        case .buffering:
            isPositionFrozen = false
            scheduleBufferingIndicator()

        case .idle, .ended:
            isPositionFrozen = false
            isBufferingVisible = false
            bufferingTask?.cancel()
            showControls()

        case .failed:
            isPositionFrozen = false
            isBufferingVisible = false
            bufferingTask?.cancel()
            showControls()
        }

        onPlaybackStateChange?(newState)
    }

    /// 处理位置更新。
    ///
    /// 三个过滤条件，缺一不可：
    /// 1. `.loading` 期间冻结（坑 2）；
    /// 2. 拖拽期间冻结（否则「拽着拽着跳回去」）；
    /// 3. 切音轨刚恢复的 350ms 内，忽略向后的跳变（引擎时钟归零的尾巴）。
    ///
    /// - Parameters:
    ///   - newPosition: 引擎上报的位置。
    ///   - engineDuration: 同一事件里携带的时长（仅作坑 1 的兜底）。
    private func handlePosition(_ newPosition: Ticks, engineDuration: Ticks) {
        // 坑 1 的兜底：万一引擎没有单独发 `.durationChanged`，用这里带的值补一次。
        if !hasDuration, engineDuration.rawValue > 0 {
            duration = engineDuration
            hasDuration = true
        }
        guard !isPositionFrozen, !isScrubbing else { return }
        guard newPosition.rawValue >= 0 else { return }

        if let deadline = resumeGuardDeadline {
            if Date() < deadline, newPosition < stablePosition {
                return
            }
            resumeGuardDeadline = nil
        }
        position = newPosition
    }

    /// 轨道列表变化后，修正当前选中项。
    ///
    /// 引擎在切音轨 / 字幕时会重发整张表；如果之前选中的索引已经不存在（例如外挂
    /// 字幕被移除），回落到第一条，避免菜单里「没有任何勾」。
    /// 按 stream id 去重，保留首次出现的顺序。
    ///
    /// - Parameter tracks: 引擎上报的轨道列表。
    /// - Returns: 去重后的列表。
    private static func uniqueTracks(_ tracks: [TrackInfo]) -> [TrackInfo] {
        var seen = Set<Int>()
        return tracks.filter { seen.insert($0.id).inserted }
    }

    private func reconcileTrackSelection() {
        if let selectedAudioIndex,
           !audioTracks.contains(where: { $0.playerIndex == selectedAudioIndex }) {
            self.selectedAudioIndex = audioTracks.first?.playerIndex
        } else if selectedAudioIndex == nil {
            selectedAudioIndex = audioTracks.first?.playerIndex
        }

        if let selectedSubtitleIndex,
           !subtitleTracks.contains(where: { $0.playerIndex == selectedSubtitleIndex }) {
            self.selectedSubtitleIndex = nil
        }
    }

    // MARK: - 播放控制

    /// 播放 / 暂停切换。
    public func togglePlayPause() async {
        switch state {
        case .playing, .buffering:
            await pause()
        default:
            await play()
        }
    }

    /// 开始播放。
    public func play() async {
        guard let engine else { return }
        await engine.play()
    }

    /// 暂停。
    public func pause() async {
        guard let engine else { return }
        await engine.pause()
    }

    /// 相对跳转。
    ///
    /// - Parameter delta: 相对秒数（正数前进）。
    public func seek(by delta: Ticks) async {
        await seek(to: position + delta)
    }

    /// 跳转到指定位置。
    ///
    /// 先做**乐观更新**（进度条立即跟手），再交给引擎；引擎随后上报的真实位置会覆盖它。
    ///
    /// - Parameter position: 目标位置。
    public func seek(to position: Ticks) async {
        let target = clamped(position)
        self.position = target
        stablePosition = target
        resumeGuardDeadline = nil
        await engine?.seek(to: target)
    }

    /// 按比例跳转（数字键 `0`–`9`）。
    ///
    /// - Parameter fraction: 0...1 的比例。
    public func seek(toFraction fraction: Double) async {
        guard hasDuration else { return }
        let clampedFraction = min(max(fraction, 0), 1)
        await seek(to: Ticks(seconds: duration.seconds * clampedFraction))
    }

    /// 把位置钳到 `0...duration`。
    ///
    /// - Parameter value: 原始位置。
    /// - Returns: 钳制后的位置。
    private func clamped(_ value: Ticks) -> Ticks {
        let lower = max(value, .zero)
        guard hasDuration else { return lower }
        return min(lower, duration)
    }

    // MARK: - 音量

    /// 相对调整音量。
    ///
    /// - Parameter delta: 增量（0.05 = 5%）。
    public func adjustVolume(by delta: Double) async {
        await setVolume(volume + delta)
    }

    /// 设置音量（0...1）。
    ///
    /// - Parameter value: 目标音量。
    public func setVolume(_ value: Double) async {
        let target = min(max(value, 0), 1)
        volume = target
        if target > 0 { isMuted = false }
        await engine?.setVolume(target)
    }

    /// 静音切换。
    public func toggleMute() async {
        isMuted.toggle()
        await engine?.setVolume(isMuted ? 0 : volume)
    }

    // MARK: - 倍速

    /// 相对调整倍速（0.25× 步进，0.25×–2×）。
    ///
    /// - Parameter delta: 增量。
    public func adjustRate(by delta: Double) async {
        await setRate(rate + delta)
    }

    /// 设置倍速。
    ///
    /// 上限取 2.0×：引擎实测的视频路径上限就是 2.0（`docs/ARCHITECTURE.md` §3.1）。
    ///
    /// - Parameter value: 目标倍速。
    public func setRate(_ value: Double) async {
        let target = min(max(value, 0.25), 2)
        rate = target
        await engine?.setRate(target)
    }

    // MARK: - 轨道

    /// 选择音轨。
    ///
    /// **注意**：切换音轨会让引擎走一次 `.loading` 重建（§3.5 坑 2），
    /// 因此这里不等待引擎回包，UI 的进度冻结由 ``handleStateChange(_:)`` 负责。
    ///
    /// - Parameter index: 引擎的 track index。
    public func selectAudioTrack(_ index: Int) async {
        guard audioTracks.contains(where: { $0.playerIndex == index }) else { return }
        selectedAudioIndex = index
        await engine?.selectAudioTrack(index)
    }

    /// 选择字幕轨；`nil` 表示关闭字幕。
    ///
    /// - Parameter index: 引擎的 track index。
    public func selectSubtitleTrack(_ index: Int?) async {
        if let index {
            guard subtitleTracks.contains(where: { $0.playerIndex == index }) else { return }
            lastSubtitleIndex = index
        }
        selectedSubtitleIndex = index
        if index == nil {
            // 关闭字幕时立刻清掉当前 cue，否则最后一句会一直贴在画面上。
            subtitleCues = []
        }
        await engine?.selectSubtitleTrack(index)
    }

    /// 循环切换音轨。
    ///
    /// 单音轨时不做任何事（引擎对同索引的切换是无操作，见 spike 结论）。
    public func cycleAudioTrack() async {
        guard audioTracks.count > 1 else { return }
        let current = selectedAudioIndex ?? audioTracks.first?.playerIndex
        let position = audioTracks.firstIndex { $0.playerIndex == current } ?? 0
        let next = audioTracks[(position + 1) % audioTracks.count]
        await selectAudioTrack(next.playerIndex)
    }

    /// 循环切换字幕轨（含「关闭」）。
    public func cycleSubtitleTrack() async {
        guard !subtitleTracks.isEmpty else { return }
        let options: [Int?] = subtitleTracks.map(\.playerIndex) + [nil]
        let currentPosition = options.firstIndex { $0 == selectedSubtitleIndex } ?? 0
        let next = options[(currentPosition + 1) % options.count]
        await selectSubtitleTrack(next)
    }

    /// 字幕显示 / 隐藏。
    ///
    /// 关闭时记住当前轨，再次打开优先恢复它（用户不想每次重新选语言）。
    public func toggleSubtitles() async {
        if selectedSubtitleIndex != nil {
            await selectSubtitleTrack(nil)
            return
        }
        guard let target = lastSubtitleIndex ?? subtitleTracks.first?.playerIndex else { return }
        await selectSubtitleTrack(target)
    }

    // MARK: - 字幕延迟

    /// 相对调整字幕延迟（±0.1s）。
    ///
    /// ⚠️ **坑 4**：引擎的 `setSubtitleDelay` 只作用于 software PiP 合成路径，
    /// 不影响自绘字幕的 cue。因此这里同时维护 ``subtitleDelay``，供字幕渲染层
    /// 自己按 `clock.sourceTime + subtitleDelay` 取值。
    ///
    /// - Parameter delta: 增量（秒）。
    public func adjustSubtitleDelay(by delta: Double) async {
        await setSubtitleDelay(subtitleDelay + delta)
    }

    /// 设置字幕延迟。
    ///
    /// - Parameter seconds: 延迟秒数，钳到 ±30s。
    public func setSubtitleDelay(_ seconds: Double) async {
        let target = min(max(seconds, -30), 30)
        subtitleDelay = target
        await engine?.setSubtitleDelay(target)
    }

    /// 字幕延迟归零。
    public func resetSubtitleDelay() async {
        await setSubtitleDelay(0)
    }

    // MARK: - 控制条自动隐藏

    /// 记录一次用户操作：显示控制条并重新计时。
    ///
    /// 鼠标移动会高频触发，这里按 0.25s 节流，避免每次移动都重建一个 `Task`。
    public func noteUserActivity() {
        let now = Date()
        let shouldReset = now.timeIntervalSince(lastActivity) > 0.25
        lastActivity = now
        if !isControlsVisible {
            isControlsVisible = true
        }
        guard shouldReset else { return }
        scheduleAutoHide()
    }

    /// 立即显示控制条（点击画面、暂停、出错时用）。
    public func showControls() {
        lastActivity = Date()
        isControlsVisible = true
        scheduleAutoHide()
    }

    /// 钉住 / 松开控制条。
    ///
    /// 菜单弹层（音轨 / 字幕 / 倍速 / 音量）展开时钉住，关闭后恢复自动隐藏——
    /// 否则用户正在挑字幕，控制条连同弹层一起淡出。
    ///
    /// - Parameter pinned: 是否钉住。
    public func setControlsPinned(_ pinned: Bool) {
        isControlsPinned = pinned
        if pinned {
            showControls()
        } else {
            scheduleAutoHide()
        }
    }

    /// 立即隐藏控制条（例如用户主动点「隐藏」；v1.0 暂未暴露入口）。
    public func hideControls() {
        autoHideTask?.cancel()
        autoHideTask = nil
        isControlsVisible = false
    }

    /// 安排 3 秒后自动隐藏。
    ///
    /// 只有「正在播放」才隐藏：暂停、缓冲、错误、拖拽时控制条常驻，
    /// 否则用户会对着静止画面找不到按钮（UX 文档 §3.10）。
    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = nil

        guard state == .playing, !isScrubbing, !isControlsPinned else { return }

        autoHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.controlsAutoHideDelay))
            guard !Task.isCancelled, let self else { return }
            guard self.state == .playing, !self.isScrubbing, !self.isControlsPinned else { return }
            self.isControlsVisible = false
        }
    }

    /// 取消自动隐藏（进入加载时用，避免用户在看不到控制条时等错误）。
    private func cancelAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = nil
    }

    // MARK: - 拖拽

    /// 开始拖拽：冻结引擎位置更新。
    public func beginScrubbing() {
        isScrubbing = true
        cancelAutoHide()
        showControls()
    }

    /// 结束拖拽：解冻并重新计时。
    public func endScrubbing() {
        isScrubbing = false
        scheduleAutoHide()
    }

    // MARK: - 缓冲指示

    /// 缓冲超过 1 秒后再显示中央转圈。
    private func scheduleBufferingIndicator() {
        bufferingTask?.cancel()
        guard !isBufferingVisible else { return }
        bufferingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.bufferingIndicatorDelay))
            guard !Task.isCancelled, let self else { return }
            guard self.state == .buffering else { return }
            self.isBufferingVisible = true
        }
    }
}
