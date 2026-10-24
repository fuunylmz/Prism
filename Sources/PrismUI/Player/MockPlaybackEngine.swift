import Foundation
import PrismCore
import PrismPlayback
import SwiftUI

// MARK: - 假引擎

/// 不依赖任何真实解码器的播放引擎实现。
///
/// 存在的意义：
/// - `#Preview` 与 UI 测试可以在**没有 AetherEngine、没有真实视频**的情况下跑完整流程；
/// - 可以把「切音轨会归零」「时长延迟可用」「失败」这些**真实引擎的坑**按需注入，
///   用来验证 UI 侧的处理是否真的生效（见 ``simulatesTrackSwitchRebuild``）。
///
/// 行为：
/// - ``load(_:)`` 发 `.loading` → 等待 ``loadingDelay`` → 发 `.durationChanged`、
///   `.tracksChanged`、`.positionChanged` → `.playing`；
/// - 播放中每 250ms 推进一次位置并发出 `.positionChanged`（4Hz，与契约一致）；
/// - ``selectAudioTrack(_:)`` 默认模拟 §3.5 坑 2：先 `.loading`，期间发一次**归零**的
///   位置，再恢复到真实位置——用来验证进度条不会闪 0。
///
/// - Important: 这是**测试替身**，不是「第二个引擎实现」：它没有解码、没有渲染，
///   ``renderView`` 只是一个黑底 `AnyView`。
@MainActor
public final class MockPlaybackEngine: PlaybackEngine {
    // MARK: 事件

    /// 播放事件流（单消费者，与协议一致）。
    public let events: AsyncStream<PlaybackEvent>

    /// 事件续写端。
    private let continuation: AsyncStream<PlaybackEvent>.Continuation

    // MARK: 可观察状态（测试可直接断言）

    /// 当前状态。
    public private(set) var state: PlaybackState = .idle

    /// 当前播放位置。
    public private(set) var position: Ticks

    /// 总时长。
    public private(set) var duration: Ticks

    /// 音量。
    public private(set) var volume: Double = 1

    /// 倍速。
    public private(set) var rate: Double = 1

    /// 字幕延迟（秒）。
    public private(set) var subtitleDelay: Double = 0

    /// 最近一次设置的字幕样式。
    public private(set) var subtitleStyle: SubtitleStyle?

    /// 最近一次挂载的外挂字幕地址。
    public private(set) var subtitleFileURL: URL?

    /// 音轨列表。
    public private(set) var audioTracks: [TrackInfo]

    /// 字幕轨列表。
    public private(set) var subtitleTracks: [TrackInfo]

    /// 当前音轨 id。
    public private(set) var currentAudioID: Int?

    /// 当前字幕轨 id；`nil` 表示关闭。
    public private(set) var currentSubtitleID: Int?

    /// `load(_:)` 被调用的次数（测试用）。
    public private(set) var loadCount = 0

    /// 收到过的播放请求（测试用）。
    public private(set) var requests: [PlaybackRequest] = []

    /// `stop()` 被调用的次数（测试用）。
    public private(set) var stopCount = 0

    // MARK: 注入项

    /// 是否自动推进位置。
    private let autoAdvance: Bool

    /// `load()` 时注入的失败；`nil` 表示正常起播。
    private let failureToInject: PlaybackFailure?

    /// 起播模拟耗时。
    private let loadingDelay: Duration

    /// 切音轨时是否模拟「`.loading` + 时钟归零」（§3.5 坑 2）。
    private let simulatesTrackSwitchRebuild: Bool

    /// 位置推进任务。
    private var tickTask: Task<Void, Never>?

    /// 创建假引擎。
    ///
    /// - Parameters:
    ///   - duration: 片长，默认 1 小时。
    ///   - startPosition: 起播位置，默认 0。
    ///   - audioTracks: 音轨列表，默认两条。
    ///   - subtitleTracks: 字幕轨列表，默认两条。
    ///   - failure: `load()` 时注入的失败。
    ///   - autoAdvance: 是否自动推进位置（预览用 `true`，单测一般 `false`）。
    ///   - loadingDelay: 模拟起播耗时，默认 80ms。
    ///   - simulatesTrackSwitchRebuild: 是否模拟切音轨重建（含时钟归零）。
    public init(
        duration: Ticks = Ticks(seconds: 3600),
        startPosition: Ticks = .zero,
        audioTracks: [TrackInfo] = MockPlaybackEngine.sampleAudioTracks,
        subtitleTracks: [TrackInfo] = MockPlaybackEngine.sampleSubtitleTracks,
        failure: PlaybackFailure? = nil,
        autoAdvance: Bool = true,
        loadingDelay: Duration = .milliseconds(80),
        simulatesTrackSwitchRebuild: Bool = true
    ) {
        self.duration = duration
        self.position = startPosition
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
        self.failureToInject = failure
        self.autoAdvance = autoAdvance
        self.loadingDelay = loadingDelay
        self.simulatesTrackSwitchRebuild = simulatesTrackSwitchRebuild
        self.currentAudioID = audioTracks.first?.id

        let (stream, continuation) = AsyncStream.makeStream(of: PlaybackEvent.self)
        self.events = stream
        self.continuation = continuation
    }

    /// 结束事件流（预览销毁时调用；正常路径由 ARC 负责）。
    deinit {
        continuation.finish()
    }

    // MARK: 渲染面

    /// 假渲染面：一块黑底，只用来占位。
    public var renderView: AnyView {
        AnyView(
            ZStack {
                Color.black
                VStack(spacing: 6) {
                    Image(systemName: "film")
                        .font(.system(size: 30, weight: .ultraLight))
                    Text("MockPlaybackEngine")
                        .font(.caption)
                }
                .foregroundStyle(.white.opacity(0.22))
            }
        )
    }

    // MARK: 协议实现

    /// 模拟加载并起播。
    ///
    /// - Parameter request: 播放请求（会被记录，供测试断言）。
    /// - Throws: 构造时注入的 ``PlaybackFailure``。
    public func load(_ request: PlaybackRequest) async throws {
        loadCount += 1
        requests.append(request)
        position = request.startPosition
        setState(.loading)

        try? await Task.sleep(for: loadingDelay)

        if let failureToInject {
            setState(.failed(failureToInject))
            emit(.failed(failureToInject))
            throw failureToInject
        }

        // 坑 1：时长在 `.loading` 之后才可用，与真实引擎一致。
        emit(.durationChanged(duration))
        emit(.tracksChanged(audio: audioTracks, subtitle: subtitleTracks))
        emit(.bufferChanged(0.35))
        emit(.positionChanged(position, duration: duration))
        setState(.playing)
        startTicking()
    }

    /// 开始 / 恢复播放。
    public func play() async {
        guard state != .playing else { return }
        setState(.playing)
        startTicking()
    }

    /// 暂停。
    public func pause() async {
        setState(.paused)
    }

    /// 跳转（精确到 tick，无误差）。
    ///
    /// - Parameter position: 目标位置。
    public func seek(to position: Ticks) async {
        let target = min(max(position, .zero), duration)
        self.position = target
        emit(.positionChanged(target, duration: duration))
    }

    /// 设置倍速。
    ///
    /// - Parameter rate: 目标倍速，钳到 0.25...2。
    public func setRate(_ rate: Double) async {
        self.rate = min(max(rate, 0.25), 2)
    }

    /// 设置音量。
    ///
    /// - Parameter volume: 目标音量，钳到 0...1。
    public func setVolume(_ volume: Double) async {
        self.volume = min(max(volume, 0), 1)
    }

    /// 切换音轨。
    ///
    /// 默认会模拟真实引擎的行为（§3.5 坑 2）：先发 `.loading`，期间位置**归零**，
    /// 再恢复。UI 侧若正确冻结进度，进度条不会闪 0。
    ///
    /// - Parameter index: 轨道 id。
    public func selectAudioTrack(_ index: Int) async {
        guard audioTracks.contains(where: { $0.id == index }) else { return }
        guard index != currentAudioID else { return }

        let resumePosition = position
        currentAudioID = index

        guard simulatesTrackSwitchRebuild else {
            emit(.tracksChanged(audio: audioTracks, subtitle: subtitleTracks))
            return
        }

        setState(.loading)
        // 真实引擎在这 86ms 里会把 sourceTime 归零。
        position = .zero
        emit(.positionChanged(.zero, duration: duration))
        try? await Task.sleep(for: .milliseconds(80))
        position = resumePosition
        emit(.positionChanged(resumePosition, duration: duration))
        emit(.tracksChanged(audio: audioTracks, subtitle: subtitleTracks))
        setState(.playing)
    }

    /// 选择字幕轨。
    ///
    /// - Parameter index: 轨道 id；`nil` 表示关闭字幕。
    public func selectSubtitleTrack(_ index: Int?) async {
        if let index {
            guard subtitleTracks.contains(where: { $0.id == index }) else { return }
        }
        currentSubtitleID = index
        emit(.tracksChanged(audio: audioTracks, subtitle: subtitleTracks))
    }

    /// 设置字幕延迟。
    ///
    /// - Parameter seconds: 延迟秒数（正值 = 字幕延后）。
    public func setSubtitleDelay(_ seconds: Double) async {
        subtitleDelay = seconds
    }

    /// 设置字幕样式。
    ///
    /// - Parameter style: 样式偏好（假引擎只保存，不渲染）。
    public func setSubtitleStyle(_ style: SubtitleStyle) async {
        subtitleStyle = style
    }

    /// 挂载 / 卸载外挂字幕。
    ///
    /// - Parameter url: 字幕地址；`nil` 表示关闭。
    public func setSubtitleFile(_ url: URL?) async {
        subtitleFileURL = url
    }

    /// 停止并回到 ``PlaybackState/idle``。
    public func stop() async {
        stopCount += 1
        tickTask?.cancel()
        tickTask = nil
        setState(.idle)
    }

    // MARK: 测试 / 预览辅助

    /// 直接注入一个状态（模拟引擎自发的迁移，例如网络抖动进入缓冲）。
    ///
    /// - Parameter state: 目标状态。
    public func simulate(_ state: PlaybackState) {
        setState(state)
    }

    /// 直接注入一次失败。
    ///
    /// - Parameter failure: 失败原因。
    public func simulate(failure: PlaybackFailure) {
        setState(.failed(failure))
        emit(.failed(failure))
    }

    /// 直接设置位置并发一条位置事件（用于测试冻结逻辑）。
    ///
    /// - Parameter position: 位置。
    public func simulate(position: Ticks) {
        self.position = position
        emit(.positionChanged(position, duration: duration))
    }

    /// 结束事件流。
    public func finishEvents() {
        continuation.finish()
    }

    // MARK: 内部

    /// 更新状态并发事件。
    ///
    /// - Parameter newState: 新状态。
    private func setState(_ newState: PlaybackState) {
        state = newState
        emit(.stateChanged(newState))
    }

    /// 发一条事件。
    ///
    /// - Parameter event: 事件。
    private func emit(_ event: PlaybackEvent) {
        continuation.yield(event)
    }

    /// 启动 4Hz 的位置推进。
    private func startTicking() {
        tickTask?.cancel()
        guard autoAdvance else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                guard self.state == .playing else { continue }
                let next = self.position + Ticks(seconds: 0.25)
                if next >= self.duration {
                    self.position = self.duration
                    self.emit(.positionChanged(self.duration, duration: self.duration))
                    self.tickTask = nil
                    self.setState(.ended)
                    self.emit(.ended)
                    return
                }
                self.position = next
                self.emit(.positionChanged(next, duration: self.duration))
            }
        }
    }

    // MARK: 样例轨道

    /// 预览 / 测试用的三条音轨。
    nonisolated public static let sampleAudioTracks: [TrackInfo] = [
        TrackInfo(
            id: 1,
            kind: .audio,
            title: "国语 AAC",
            language: "chi",
            codec: "aac",
            channels: 2,
            isDefault: true
        ),
        TrackInfo(
            id: 2,
            kind: .audio,
            title: "English E-AC3",
            language: "eng",
            codec: "eac3",
            channels: 6
        ),
        TrackInfo(
            id: 3,
            kind: .audio,
            title: "日本語 DTS-HD",
            language: "jpn",
            codec: "dts",
            channels: 8
        )
    ]

    /// 预览 / 测试用的三条字幕轨（含一条外挂）。
    nonisolated public static let sampleSubtitleTracks: [TrackInfo] = [
        TrackInfo(
            id: 4,
            kind: .subtitle,
            title: "简体中文 ASS",
            language: "chi",
            codec: "ass",
            isDefault: true,
            isTextSubtitle: true
        ),
        TrackInfo(
            id: 5,
            kind: .subtitle,
            title: "English PGS",
            language: "eng",
            codec: "hdmv_pgs_subtitle"
        ),
        TrackInfo(
            id: 100_000,
            kind: .subtitle,
            title: "日本語 SRT",
            language: "jpn",
            codec: "subrip",
            isExternal: true,
            isTextSubtitle: true
        )
    ]
}

// MARK: - 预览数据

/// `#Preview` 用的视图模型快照。
///
/// 每个工厂都返回一份**已经处于目标状态**的视图模型，不需要跑引擎、不需要等异步：
/// 预览里看到的「暂停 / 缓冲 / 错误 / 控制条隐藏」就是最终形态。
@MainActor
enum PlayerPreviewModel {
    /// 片长（1:42:10）。
    private static let duration = Ticks(seconds: 6130)

    /// 播放中。
    static func playing() -> PlayerViewModel {
        PlayerViewModel(
            previewState: .playing,
            position: Ticks(seconds: 754),
            duration: duration,
            buffered: Ticks(seconds: 2400),
            audioTracks: MockPlaybackEngine.sampleAudioTracks,
            subtitleTracks: MockPlaybackEngine.sampleSubtitleTracks,
            subtitleCues: [
                SubtitleCue(
                    id: 1,
                    start: Ticks(seconds: 700),
                    end: Ticks(seconds: 800),
                    body: .text("这是字幕显示预览")
                )
            ],
            selectedAudioIndex: 1,
            selectedSubtitleIndex: 4,
            volume: 0.8
        )
    }

    /// 暂停。
    static func paused() -> PlayerViewModel {
        PlayerViewModel(
            previewState: .paused,
            position: Ticks(seconds: 2210),
            duration: duration,
            buffered: Ticks(seconds: 3600),
            audioTracks: MockPlaybackEngine.sampleAudioTracks,
            subtitleTracks: MockPlaybackEngine.sampleSubtitleTracks,
            selectedAudioIndex: 2,
            selectedSubtitleIndex: nil,
            volume: 0.55,
            isMuted: true
        )
    }

    /// 缓冲中（转圈已显示）。
    static func buffering() -> PlayerViewModel {
        PlayerViewModel(
            previewState: .buffering,
            position: Ticks(seconds: 1200),
            duration: duration,
            buffered: Ticks(seconds: 1215),
            audioTracks: MockPlaybackEngine.sampleAudioTracks,
            subtitleTracks: MockPlaybackEngine.sampleSubtitleTracks,
            selectedAudioIndex: 1,
            isBufferingVisible: true
        )
    }

    /// 起播加载（坑 1：时长仍为 0）。
    static func loading() -> PlayerViewModel {
        PlayerViewModel(
            previewState: .loading,
            position: .zero,
            duration: .zero,
            buffered: .zero
        )
    }

    /// 错误。
    static func failed() -> PlayerViewModel {
        PlayerViewModel(
            previewState: .failed(
                PlaybackFailure(
                    kind: .unsupportedMedia,
                    message: "AVFoundation: unsupported codec (preview)",
                    isRecoverable: false
                )
            ),
            position: Ticks(seconds: 42),
            duration: duration,
            audioTracks: MockPlaybackEngine.sampleAudioTracks
        )
    }

    /// 控制条已自动隐藏。
    static func controlsHidden() -> PlayerViewModel {
        PlayerViewModel(
            previewState: .playing,
            position: Ticks(seconds: 3300),
            duration: duration,
            buffered: Ticks(seconds: 4200),
            audioTracks: MockPlaybackEngine.sampleAudioTracks,
            subtitleTracks: MockPlaybackEngine.sampleSubtitleTracks,
            selectedAudioIndex: 1,
            selectedSubtitleIndex: 5,
            isControlsVisible: false
        )
    }

    /// 播放结束。
    static func ended() -> PlayerViewModel {
        PlayerViewModel(
            previewState: .ended,
            position: duration,
            duration: duration,
            buffered: duration,
            audioTracks: MockPlaybackEngine.sampleAudioTracks,
            subtitleTracks: MockPlaybackEngine.sampleSubtitleTracks,
            selectedAudioIndex: 1
        )
    }
}

// MARK: - 预览

/// 实时预览：用假引擎跑一遍「加载 → 播放」，验证事件链路。
@MainActor
private struct MockEngineLivePreview: View {
    @State private var model = PlayerViewModel()
    @State private var engine: MockPlaybackEngine?

    var body: some View {
        PlayerView(
            model: model,
            title: "MockPlaybackEngine · 实时预览",
            subtitle: "假引擎：4Hz 位置事件 · 切音轨会模拟归零",
            hasNext: true,
            onTogglePiP: {}
        )
        .frame(width: 960, height: 540)
        .task {
            let engine = MockPlaybackEngine(
                duration: Ticks(seconds: 600),
                startPosition: Ticks(seconds: 30)
            )
            self.engine = engine
            await model.attach(engine: engine)
            try? await engine.load(
                PlaybackRequest(
                    url: URL(filePath: "/mock/prism-stream.mkv"),
                    method: .directPlay,
                    startPosition: Ticks(seconds: 30)
                )
            )
        }
    }
}

#Preview("MockPlaybackEngine · 实时") {
    MockEngineLivePreview()
        .prismTheme(PrismTheme(appearance: .dark))
}
