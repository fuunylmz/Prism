import AppKit
import AetherEngine
import Foundation
import PrismCore
import SwiftUI

/// ``PlaybackEngine`` 的 AetherEngine 实现（T3.1）。
///
/// ## 铁律：AetherEngine 类型零泄漏
///
/// **这是全仓库唯一 `import AetherEngine` 的文件**。协议 ``PlaybackEngine`` 及其所有返回值
/// 都不得出现 AetherEngine 的类型；CI 的检查命令是：
///
/// ```bash
/// grep -rl "import AetherEngine" Sources/ --include=*.swift | grep -v AetherEngineAdapter
/// # 必须为空
/// ```
///
/// 所以本文件之外只出现 Prism 自己的值类型，AetherEngine 的类型一律在这里就地映射。
///
/// ## 实现要点（对应 `docs/ARCHITECTURE.md` §3.1 的映射表）
///
/// | 协议方法 | AetherEngine |
/// |---|---|
/// | `load(_:)` | `player.load(url:startPosition:options:)`，鉴权头走 `options.httpHeaders` |
/// | `play()` / `pause()` | `player.play()` / `player.pause()` |
/// | `seek(to:)` | `await player.seek(to: 秒)` |
/// | `setRate(_:)` | `player.setRate(Float)`（上限 2.0，超出静默钳制） |
/// | `setVolume(_:)` | `player.volume` |
/// | `selectAudioTrack(_:)` | `player.selectAudioTrack(index:)` |
/// | `selectSubtitleTrack(_:)` | `player.selectSubtitleTrack(index:)` / `player.clearSubtitle()` |
/// | `setSubtitleDelay(_:)` | `player.setSoftwareSubtitleDelay` **+ 自己维护偏移**（坑 4） |
/// | `setSubtitleStyle(_:)` | **无引擎 API**，只保存（§3.3 缺口） |
/// | `setSubtitleFile(_:)` | `player.addExternalSubtitleTrack(_:)` |
/// | `stop()` | `player.stop()` |
/// | `events` | `AsyncPublisher`（`$state.values` 等）→ ``AsyncStream`` |
///
/// ## 实测坑（§3.5，全部在这里处理）
///
/// 1. **`duration` 延迟**：`load()` 返回时是 0，61ms 后才可用 → 不读 `player.duration`，
///    改由 `$duration` 观察，收到非零值再发 ``PlaybackEvent/durationChanged(_:)``。
/// 2. **切音轨归零**：`selectAudioTrack` 触发 143ms 重建，`sourceTime` 归零约 86ms →
///    重建期间冻结位置事件、改发 ``PlaybackState/loading``，重建结束后补发一次正确位置。
/// 3. **ASS 部分支持**：`\fad` / `\bord` / `\shad` / `\fscx` 不支持 → 写进
///    ``SubtitleStyle`` 的文档，让 UI 侧知道哪些样式能生效。
/// 4. **字幕延迟不生效**：`setSoftwareSubtitleDelay` 只作用于 software PiP →
///    自己维护偏移，在发 ``PlaybackEvent/subtitleCues(_:)`` 时对时间轴施加。
///
/// ## 线程模型
///
/// AetherEngine 是 `@MainActor` 的，所以适配器整体也是 `@MainActor`；
/// 协议方法是 `async`，调用方从任意上下文 `await` 即可（会切到主 actor）。
/// 事件由主 actor 上的 `for await` 泵出，通过 ``PlaybackEventBridge``（`Sendable`）交给消费者。
@MainActor
public final class AetherEngineAdapter: PlaybackEngine {

    // MARK: - 引擎与渲染面

    /// 真正的引擎实例。除本文件外没有任何代码能看到它的类型。
    private let player: AetherEngine

    /// 离屏渲染面。
    ///
    /// 实测（`playback-spike-results.md` §1）：`bind(view:)` 给一个**没有窗口**的视图就能正常
    /// `load`，所以这里在 `init` 就绑好，保证「先 load 再上屏」也安全。
    private let offscreenSurface: AetherPlayerView

    /// 交给 SwiftUI 的渲染面（`AetherPlayerSurface` 会自己创建并绑定视图）。
    private let surface: AnyView

    /// 事件出口。
    private let bridge: PlaybackEventBridge

    /// 日志（可注入；`nil` 表示不记）。
    private let logger: (any Logging)?

    // MARK: - 状态

    /// 状态机：过滤引擎的瞬时中间态与非法迁移。
    private var machine = PlaybackStateMachine()

    /// 位置闸门（坑 2）。
    private var positionGate = PlaybackPositionGate()

    /// 字幕时间轴闸门（坑 4）。
    private var subtitleTimeline = SubtitleTimelineGate()

    /// 当前字幕样式（引擎没有样式 API，只在这里保存给 UI 用）。
    private var style: SubtitleStyle = .default

    /// 最近一次发布的音频轨。
    private var audioTracks: [TrackInfo] = []

    /// 最近一次发布的字幕轨。
    private var subtitleTracks: [TrackInfo] = []

    /// 已转码的位图 cue，按引擎快照中的 cue id 缓存，避免每个时钟更新都重编码。
    private var bitmapSubtitleCache: [Int: SubtitleBitmap] = [:]

    /// 上一次已发布的轨道快照（用于去重）。
    private var lastAudioTracks: [TrackInfo]?
    private var lastSubtitleTracks: [TrackInfo]?

    /// 上一次已发布的时长。
    private var lastDuration: Ticks = .zero

    /// 上一次已发布的缓冲比例。
    private var lastBufferFraction: Double = -1

    /// 是否处于「切音轨重建」中（坑 2）。
    private var isRebuilding = false

    /// 观察任务（适配器销毁时自动取消）。
    private let observationTasks = PlaybackTaskBag()

    /// 重建兜底超时任务。
    private var rebuildTimeout: Task<Void, Never>?

    // MARK: - 生命周期

    /// 创建适配器。
    ///
    /// 会立刻构造引擎、绑定一个离屏渲染面，并开始观察引擎状态。
    ///
    /// - Parameter logger: 可选日志出口。
    /// - Throws: 引擎构造失败时抛出（AetherEngine 初始化会做 FFmpeg 运行时检查）。
    public init(logger: (any Logging)? = nil) throws {
        let engine = try AetherEngine()
        let offscreen = AetherPlayerView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        engine.bind(view: offscreen)

        self.player = engine
        self.offscreenSurface = offscreen
        self.surface = AnyView(AetherPlayerSurface(engine: engine))
        self.bridge = PlaybackEventBridge()
        self.logger = logger

        startObservation()
    }

    deinit {
        bridge.finish()
    }

    // MARK: - PlaybackEngine：渲染与事件

    /// SwiftUI 渲染面。内部已把引擎图层绑好，直接塞进 `body` 即可。
    public var renderView: AnyView { surface }

    /// AppKit 渲染面（离屏那个视图）。
    ///
    /// - Important: 与 ``renderView`` **二选一**：两个都用会出现两个渲染面
    ///   （引擎会把画面挂到最后绑定的那个上）。UI 是 SwiftUI 时用 ``renderView``。
    public var renderNSView: NSView { offscreenSurface }

    /// 播放事件流（单消费者）。
    public nonisolated var events: AsyncStream<PlaybackEvent> { bridge.events }

    // MARK: - PlaybackEngine：传输控制

    /// 加载并起播。
    ///
    /// - Parameter request: 播放请求。
    /// - Throws: ``PlaybackFailure``。
    public func load(_ request: PlaybackRequest) async throws {
        resetSession(emitIdle: false)
        applyState(.loading)
        logger?.info("开始加载 \(request.url.lastPathComponent)，方式=\(String(describing: request.method))")

        var options = LoadOptions(httpHeaders: request.headers)
        options.externalSubtitles = request.externalSubtitles.map(Self.makeExternalTrack)

        let startPosition = request.startPosition > .zero ? request.startPosition.seconds : nil
        let audioIndex = request.audioStreamIndex.map { Int32($0) }

        do {
            _ = try await player.load(
                url: request.url,
                startPosition: startPosition,
                options: options,
                audioSourceStreamIndex: audioIndex
            )
        } catch is CancellationError {
            let failure = PlaybackFailure(kind: .cancelled, message: "加载被取消")
            applyState(.idle)
            throw failure
        } catch {
            let failure = PlaybackFailure(
                kind: Self.classifyLoadError(error),
                message: error.localizedDescription
            )
            applyState(.failed(failure))
            bridge.yield(.failed(failure))
            throw failure
        }

        // 起播时选中字幕（坑 4 的偏移在发 cue 时才施加，这里只管选轨）。
        if let subtitleIndex = request.subtitleStreamIndex {
            let engineIndex = request.externalSubtitles.firstIndex { $0.id == String(subtitleIndex) }
                .map { AetherEngine.externalSubtitleTrackIDBase + $0 }
                ?? subtitleIndex
            player.selectSubtitleTrack(index: engineIndex)
        }

        // 坑 1：这里**不读** player.duration（此刻还是 0），等 $duration 观察者发事件。
        logger?.info("加载完成（duration 由事件补发）")
    }

    /// 开始 / 恢复播放。
    public func play() async {
        player.play()
    }

    /// 暂停。
    public func pause() async {
        player.pause()
    }

    /// 跳转到绝对位置。
    ///
    /// - Parameter position: 目标位置；负值按 0 处理。
    public func seek(to position: Ticks) async {
        guard machine.state.isActive else { return }
        let target = max(position, .zero)
        await player.seek(to: target.seconds)
        // seek 之后强制补发一次位置，避免 UI 等下一个 10Hz tick。
        let landed = Ticks(seconds: max(0, player.clock.currentTime))
        if let event = positionGate.accept(position: landed, duration: lastDuration, force: true) {
            bridge.yield(event)
        }
    }

    /// 设置速率。引擎会把速率钳到 `maxSupportedRate`（视频 2.0）。
    ///
    /// - Parameter rate: 目标速率（1.0 = 正常）。
    public func setRate(_ rate: Double) async {
        guard rate.isFinite else { return }
        player.setRate(Float(rate))
    }

    /// 设置音量。
    ///
    /// - Parameter volume: 0...1，越界钳制。
    public func setVolume(_ volume: Double) async {
        guard volume.isFinite else { return }
        player.volume = Float(min(max(volume, 0), 1))
    }

    /// 停止播放并释放解码器。
    public func stop() async {
        player.stop()
        resetSession(emitIdle: true)
    }

    // MARK: - PlaybackEngine：轨道

    /// 切换音轨（坑 2）。
    ///
    /// 切换会触发一次管线重建；期间本适配器冻结位置事件并改发 ``PlaybackState/loading``，
    /// 重建结束后补发一次正确位置。
    ///
    /// - Parameter index: 轨道 id（``TrackInfo/id``）。
    public func selectAudioTrack(_ index: Int) async {
        guard player.audioTracks.contains(where: { $0.id == index }) else {
            logger?.warning("音轨 \(index) 不在当前轨道列表里，忽略")
            return
        }
        guard player.activeAudioTrackIndex != index else { return }

        beginRebuild()
        player.selectAudioTrack(index: index)
    }

    /// 选择字幕轨。
    ///
    /// - Parameter index: 轨道 id；`nil` = 关闭字幕。
    public func selectSubtitleTrack(_ index: Int?) async {
        if let index {
            player.selectSubtitleTrack(index: index)
        } else {
            player.clearSubtitle()
        }
    }

    /// 设置字幕延迟（坑 4）。
    ///
    /// 引擎的 `setSoftwareSubtitleDelay` 只影响 software PiP，不影响自绘字幕的 cue；
    /// 这里自己维护偏移量，并在发 ``PlaybackEvent/subtitleCues(_:)`` 时施加到时间轴。
    ///
    /// - Parameter seconds: 秒；正 = 延后，负 = 提前。
    public func setSubtitleDelay(_ seconds: Double) async {
        guard seconds.isFinite else { return }
        let changed = subtitleTimeline.setDelay(seconds)
        // 仍然通知引擎：PiP 合成路径需要它（自绘路径由上面的闸门负责）。
        player.setSoftwareSubtitleDelay(seconds)
        if changed {
            deliverCues()
        }
    }

    /// 设置字幕样式。
    ///
    /// - Note: 引擎**没有**字幕样式 API（§3.3 缺口）；字幕由 Prism 自绘，
    ///   这个值只保存下来供 UI 消费。ASS 覆盖标签的支持边界见 ``SubtitleStyle``。
    ///
    /// - Parameter style: 样式偏好。
    public func setSubtitleStyle(_ style: SubtitleStyle) async {
        self.style = style
    }

    /// 挂载 / 卸载外挂字幕。
    ///
    /// - Parameter url: 字幕文件；`nil` = 关闭当前字幕（引擎没有注销外挂轨的 API，
    ///   已注册的轨会留在列表里直到下一次 `load()`）。
    public func setSubtitleFile(_ url: URL?) async {
        guard let url else {
            player.clearSubtitle()
            return
        }
        let track = ExternalSubtitleTrack(
            url: url,
            name: url.deletingPathExtension().lastPathComponent,
            language: nil,
            formatHint: url.pathExtension.isEmpty ? nil : url.pathExtension
        )
        let info = player.addExternalSubtitleTrack(track)
        player.selectSubtitleTrack(index: info.id)
    }

    // MARK: - 对外只读状态（便利）

    /// 当前状态（状态机视角）。
    public var currentState: PlaybackState { machine.state }

    /// 当前是否可 seek。
    public var canSeek: Bool { player.canSeek }

    /// 当前路径支持的最大速率（视频 2.0、纯音频 3.0）。
    public var maxRate: Double { Double(player.maxSupportedRate) }

    /// 当前音轨 id。
    public var activeAudioTrackIndex: Int? { player.activeAudioTrackIndex }

    /// 当前字幕轨 id（`nil` = 关闭）。
    public var activeSubtitleTrackIndex: Int? { player.activeSubtitleTrackIndex }

    /// 当前字幕样式。
    public var subtitleStyle: SubtitleStyle { style }

    /// 当前字幕延迟（秒）。
    public var subtitleDelay: Double { subtitleTimeline.delay }

    // MARK: - 观察（Combine AsyncPublisher → AsyncStream）

    /// 起泵：把引擎的 `@Published` 变成事件。
    ///
    /// §3.2 要求优先用 `AsyncPublisher`（`$state.values`），而不是手写 `sink` + `AnyCancellable`
    /// ——后者不是 `Sendable`，在 Swift 6 严格并发下存不进主 actor 之外的地方。
    private func startObservation() {
        let engine = player

        // 状态
        //
        // 注意：`switch` 直接写在这里而不是抽成 `handle(engineState:)`——AetherEngine 的
        // `PlaybackState` 与本模块的 ``PlaybackState`` 同名，函数签名里无法写类型名
        // （`AetherEngine.PlaybackState` 会被解析成 `AetherEngine` 这个**类**的成员）。
        // 用闭包内联就能让编译器自己推断，同时保持「只有这一个文件 import AetherEngine」。
        observationTasks.add(Task { @MainActor [weak self] in
            for await state in engine.$state.values {
                guard let self else { return }
                switch state {
                case .idle:
                    self.applyState(.idle)
                case .loading:
                    self.applyState(.loading)
                case .playing:
                    self.applyState(.playing)
                    self.finishRebuildIfNeeded()
                case .paused:
                    self.applyState(.paused)
                    self.finishRebuildIfNeeded()
                case .seeking:
                    // 引擎的 seeking 是瞬时中间态，契约里没有对应状态；
                    // 位置由 seek(to:) 自己补发，这里不制造状态抖动。
                    break
                case .ended:
                    self.applyState(.ended)
                    self.bridge.yield(.ended)
                case .error(let message):
                    self.handleEngineError(message)
                }
            }
        })

        // 时长（坑 1：load() 返回时是 0，这里等非零值）
        observationTasks.add(Task { @MainActor [weak self] in
            for await duration in engine.$duration.values {
                guard let self else { return }
                self.handleDuration(duration)
            }
        })

        // 音频轨（映射内联：`AetherEngine.TrackInfo` 与本模块的 ``TrackInfo`` 同名，
        // 写不进函数签名，只能靠闭包参数推断）
        observationTasks.add(Task { @MainActor [weak self] in
            for await tracks in engine.$audioTracks.values {
                guard let self else { return }
                self.audioTracks = tracks.map { track in
                    TrackInfo(
                        id: track.id,
                        kind: .audio,
                        title: track.name,
                        language: track.language,
                        codec: track.codec,
                        channels: track.channels,
                        isDefault: track.isDefault,
                        isForced: track.isForced,
                        isExternal: track.isExternal,
                        isTextSubtitle: false
                    )
                }
                self.publishTracksIfChanged()
            }
        })

        // 字幕轨
        observationTasks.add(Task { @MainActor [weak self] in
            for await tracks in engine.$subtitleTracks.values {
                guard let self else { return }
                self.subtitleTracks = tracks.map { track in
                    TrackInfo(
                        id: track.id,
                        kind: .subtitle,
                        title: track.name,
                        language: track.language,
                        codec: track.codec,
                        channels: track.channels,
                        isDefault: track.isDefault,
                        isForced: track.isForced,
                        isExternal: track.isExternal,
                        isTextSubtitle: !TrackInfo.isBitmapSubtitleCodec(track.codec)
                    )
                }
                self.publishTracksIfChanged()
            }
        })

        // 字幕 cue（坑 4：发出去之前施加延迟偏移）
        //
        // 映射同样内联：`AetherEngine.SubtitleCue` 与本模块的 ``SubtitleCue`` 同名。
        observationTasks.add(Task { @MainActor [weak self] in
            for await cues in engine.$subtitleCues.values {
                guard let self else { return }
                let cueIDs = Set(cues.map(\.id))
                self.bitmapSubtitleCache = self.bitmapSubtitleCache.filter { cueIDs.contains($0.key) }
                let mapped: [SubtitleCue] = cues.compactMap { cue in
                    let body: SubtitleCue.Body
                    switch cue.body {
                    case .text(let text):
                        body = .text(text)
                    case .richText(let runs):
                        body = .richText(runs.map { run in
                            SubtitleCue.TextRun(
                                text: run.text,
                                color: run.color.map { SubtitleColor(r: $0.r, g: $0.g, b: $0.b) },
                                isBold: run.isBold,
                                isItalic: run.isItalic,
                                isUnderlined: run.isUnderlined,
                                isStruckThrough: run.isStruckThrough,
                                fontName: run.fontName,
                                fontSize: run.fontSize.map(Double.init)
                            )
                        })
                    case let .image(image):
                        let bitmap: SubtitleBitmap
                        if let cached = self.bitmapSubtitleCache[cue.id] {
                            bitmap = cached
                        } else {
                            guard let data = NSBitmapImageRep(cgImage: image.cgImage)
                                .representation(using: .png, properties: [:]) else { return nil }
                            bitmap = SubtitleBitmap(
                                pngData: data,
                                x: image.position.origin.x,
                                y: image.position.origin.y,
                                width: image.position.width,
                                height: image.position.height,
                                canvasWidth: image.canvasSize.width,
                                canvasHeight: image.canvasSize.height,
                                isForced: image.isForced
                            )
                        }
                        self.bitmapSubtitleCache[cue.id] = bitmap
                        body = .image(bitmap)
                    }
                    let placement = cue.placement.map {
                        SubtitleCue.Placement(alignment: $0.alignment, position: $0.position)
                    }
                    return SubtitleCue(
                        id: cue.id,
                        start: Ticks(seconds: cue.startTime),
                        end: Ticks(seconds: cue.endTime),
                        body: body,
                        placement: placement
                    )
                }
                self.handleCues(mapped)
            }
        })

        // 缓冲中标记（引擎在 rebuffer 时保持 .playing，靠这个区分）
        observationTasks.add(Task { @MainActor [weak self] in
            for await isBuffering in engine.$isBuffering.values {
                guard let self else { return }
                self.handleBuffering(isBuffering)
            }
        })

        // 位置（~10Hz）
        observationTasks.add(Task { @MainActor [weak self] in
            for await time in engine.clock.$currentTime.values {
                guard let self else { return }
                self.handleClock(time)
            }
        })

        // 缓冲进度
        observationTasks.add(Task { @MainActor [weak self] in
            for await buffered in engine.clock.$bufferedPosition.values {
                guard let self else { return }
                self.handleBuffered(buffered)
            }
        })
    }

    // MARK: - 事件处理

    /// 处理引擎的 `.error` 状态。
    ///
    /// - Parameter message: 引擎给的错误文案（已本地化，只用于日志）。
    private func handleEngineError(_ message: String) {
        let kind = Self.classify(kindName: player.errorInfo?.kind.rawValue)
        let failure = PlaybackFailure(
            kind: kind,
            message: message,
            isRecoverable: kind == .network
        )
        applyState(.failed(failure))
        bridge.yield(.failed(failure))
        logger?.error("播放失败：\(failure.kind.rawValue) / \(message)")
    }

    /// 处理时长变化（坑 1）。
    ///
    /// - Parameter seconds: 引擎给的时长（秒）；`0` 表示还不知道，忽略。
    private func handleDuration(_ seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        let duration = Ticks(seconds: seconds)
        guard duration != lastDuration else { return }
        lastDuration = duration
        positionGate.setDuration(duration)
        bridge.yield(.durationChanged(duration))
    }

    /// 处理时钟位置。
    ///
    /// - Parameter seconds: `clock.currentTime`（显示轴）。
    private func handleClock(_ seconds: Double) {
        guard machine.state.isActive, seconds.isFinite else { return }
        let position = Ticks(seconds: max(0, seconds))
        if let event = positionGate.accept(position: position, duration: lastDuration) {
            bridge.yield(event)
        }
    }

    /// 处理缓冲进度。
    ///
    /// - Parameter seconds: 已缓冲到的位置（秒）。
    private func handleBuffered(_ seconds: Double) {
        guard seconds.isFinite else { return }
        let total = player.duration
        guard total.isFinite, total > 0 else { return }
        let fraction = min(max(seconds / total, 0), 1)
        guard abs(fraction - lastBufferFraction) >= 0.005 else { return }
        lastBufferFraction = fraction
        bridge.yield(.bufferChanged(fraction))
    }

    /// 处理 rebuffer 标记。
    ///
    /// - Parameter isBuffering: 引擎的 `isBuffering`。
    private func handleBuffering(_ isBuffering: Bool) {
        guard !isRebuilding else { return }
        switch (isBuffering, machine.state) {
        case (true, .playing):
            applyState(.buffering)
        case (false, .buffering):
            applyState(.playing)
        default:
            break
        }
    }

    /// 处理字幕 cue（坑 4：施加延迟后发出）。
    ///
    /// - Parameter cues: 引擎发布的 cue（原始媒体时间轴）。
    private func handleCues(_ cues: [SubtitleCue]) {
        subtitleTimeline.update(cues: cues)
        deliverCues()
    }

    /// 把当前 cue 施加延迟偏移后发出去。
    private func deliverCues() {
        bridge.yield(.subtitleCues(subtitleTimeline.shiftedCues))
    }

    /// 轨道列表有变化时才发事件。
    private func publishTracksIfChanged() {
        guard lastAudioTracks != audioTracks || lastSubtitleTracks != subtitleTracks else { return }
        lastAudioTracks = audioTracks
        lastSubtitleTracks = subtitleTracks
        bridge.yield(.tracksChanged(audio: audioTracks, subtitle: subtitleTracks))
    }

    // MARK: - 状态机

    /// 走状态机并（在合法时）发事件。
    ///
    /// - Parameter next: 目标状态。
    private func applyState(_ next: PlaybackState) {
        switch machine.apply(next) {
        case .accepted:
            bridge.yield(.stateChanged(next))
        case .unchanged:
            break
        case .rejected:
            logger?.debug("丢弃非法状态迁移 \(String(describing: machine.state)) -> \(String(describing: next))")
        }
    }

    // MARK: - 切轨重建（坑 2）

    /// 进入重建：冻结位置、发 `loading`、装兜底超时。
    private func beginRebuild() {
        isRebuilding = true
        positionGate.freeze()
        applyState(.loading)

        rebuildTimeout?.cancel()
        rebuildTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.isRebuilding else { return }
            self.logger?.warning("切轨重建 3s 未回到播放态，强制解冻位置")
            self.applyState(.playing)
            self.finishRebuildIfNeeded()
        }
    }

    /// 重建结束：解冻并用「冻结前的最后有效位置」补发一次。
    ///
    /// 为什么不用当时的 `clock.currentTime`：实测重建刚回到 `.playing` 的那 ~50ms 里时钟还是 0
    /// （`t+0.101s playing / sourceTime=0.000`，`t+0.155s` 才回到 9.072）。直接用会发一个 0 出去。
    private func finishRebuildIfNeeded() {
        guard isRebuilding else { return }
        isRebuilding = false
        rebuildTimeout?.cancel()
        rebuildTimeout = nil
        let clockPosition = Ticks(seconds: max(0, player.clock.currentTime))
        bridge.yield(positionGate.thaw(clockPosition: clockPosition))
    }

    // MARK: - 会话重置

    /// 重置所有会话内状态。
    ///
    /// - Parameter emitIdle: 是否补发一次 `.stateChanged(.idle)`（`stop()` 用）。
    private func resetSession(emitIdle: Bool) {
        rebuildTimeout?.cancel()
        rebuildTimeout = nil
        isRebuilding = false
        positionGate.reset()
        subtitleTimeline.reset()
        bitmapSubtitleCache.removeAll(keepingCapacity: false)
        audioTracks = []
        subtitleTracks = []
        lastAudioTracks = nil
        lastSubtitleTracks = nil
        lastDuration = .zero
        lastBufferFraction = -1

        let previous = machine.state
        machine.force(.idle)
        if emitIdle && previous != .idle {
            bridge.yield(.stateChanged(.idle))
        }
        bridge.yield(.tracksChanged(audio: [], subtitle: []))
        bridge.yield(.subtitleCues([]))
    }

    // MARK: - 引擎类型映射（AetherEngine → Prism）

    /// 我们的外挂字幕 → 引擎的外挂字幕。
    ///
    /// - Parameter track: 外挂字幕。
    private static func makeExternalTrack(_ track: SubtitleTrack) -> ExternalSubtitleTrack {
        ExternalSubtitleTrack(
            url: track.url,
            name: track.title,
            language: track.language,
            isForced: track.isForced,
            isHearingImpaired: track.isHearingImpaired,
            isDefault: track.isDefault,
            httpHeaders: track.httpHeaders,
            formatHint: formatHint(for: track.format)
        )
    }

    /// 字幕格式 → 引擎的扩展名提示。
    ///
    /// - Parameter format: 我们的格式枚举。
    private static func formatHint(for format: SubtitleTrack.Format) -> String? {
        switch format {
        case .srt: "srt"
        case .ass: "ass"
        case .ssa: "ssa"
        case .vtt: "vtt"
        case .pgs: "sup"
        case .other: nil
        }
    }

    /// 把引擎的错误分类成 ``PlaybackFailure/Kind``。
    ///
    /// 引擎的 `PlaybackErrorKind` 是字符串结构体（不透明枚举），这里按它的稳定 rawValue 归类。
    ///
    /// - Parameter info: 引擎错误信息（可能为 `nil`）。
    private static func makeFailure(
        message: String,
        info: PlaybackErrorInfo?
    ) -> PlaybackFailure {
        let kind = classify(kindName: info?.kind.rawValue)
        return PlaybackFailure(kind: kind, message: message, isRecoverable: kind == .network)
    }

    /// 错误种类名 → 我们的分类。
    ///
    /// - Parameter kindName: 引擎 `PlaybackErrorKind.rawValue`。
    private static func classify(kindName: String?) -> PlaybackFailure.Kind {
        guard let kindName else { return .unknown }
        switch kindName {
        case "sourceRefused", "sourceRateLimited", "sourceCertificateRejected",
             "vodSourceFailed", "liveSourceUnavailable", "liveReloadNeverReady":
            return .network
        case "sourceOpenFailed", "customSourceProbeFailed", "reloadFailed",
             "hlsPlaylistOnRawLivePath":
            return .load
        case "dolbyVisionRequiresHardware", "demuxedAudioLiveUnsupported",
             "noPlayableTrackWithinBudget", "masterPlaylistRejected":
            return .unsupportedMedia
        case "softwarePipelineFailed", "nativeItemFailed", "audioSessionFailed",
             "audioTrackSwitchFailed":
            return .decode
        default:
            return .unknown
        }
    }

    /// 加载抛错的分类。
    ///
    /// - Parameter error: `load` 抛出的错误。
    private static func classifyLoadError(_ error: any Error) -> PlaybackFailure.Kind {
        if let failure = error as? PlaybackFailure { return failure.kind }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain { return .network }
        return .load
    }
}

// MARK: - 任务袋

/// 一组观察任务的容器：适配器销毁时统一取消。
///
/// 为什么不用 `[Task]` 数组：`@MainActor` 类型的 `deinit` 是 nonisolated 的，碰不到隔离属性；
/// 而 Task 若没人取消，会一直持有引擎实例（泵是 `for await` 的无限循环）。
/// 把任务放进一个 `Sendable` 的独立对象里，它的 `deinit` 就能安全地取消它们。
private final class PlaybackTaskBag: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []
    private var isCancelled = false

    /// 收一个任务；若已取消则立刻取消它。
    ///
    /// - Parameter task: 观察任务。
    func add(_ task: Task<Void, Never>) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            task.cancel()
            return
        }
        tasks.append(task)
        lock.unlock()
    }

    /// 取消全部任务。
    func cancelAll() {
        lock.lock()
        isCancelled = true
        let all = tasks
        tasks = []
        lock.unlock()
        for task in all { task.cancel() }
    }

    deinit {
        cancelAll()
    }
}
