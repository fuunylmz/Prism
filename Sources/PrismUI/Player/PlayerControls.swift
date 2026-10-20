import PrismCore
import SwiftUI

// MARK: - 控制条

/// 播放器底部控制条。
///
/// 布局（`docs/research/ux-benchmark.md` §3.10）：
///
/// ```
/// ┌──────────────────────────────────────────────────────────────┐
/// │ 12:34 ──────●────────────────────── 1:42:10                  │  ← 进度条（hover 显示时间）
/// │ ▶  ⏮  ⏭          12:34 / 1:42:10        🔊 音轨 字幕 倍速 PiP ⛶ │
/// └──────────────────────────────────────────────────────────────┘
/// ```
///
/// 所有按钮都是 ``PrismIconButton``；音轨 / 字幕 / 倍速 / 音量用 `popover` 承载，
/// 而不是 `Menu`——这样按钮外观与其它图标按钮完全一致，也不会在深色视频上出现
/// 系统菜单的浅色描边。
///
/// 本视图**不处理**自动隐藏：可见性由 ``PlayerViewModel/isControlsVisible`` 与
/// ``PlayerView`` 的淡入淡出负责。
public struct PlayerControls: View {
    /// 视图模型。
    private let model: PlayerViewModel

    /// 是否有上一集 / 下一集。
    private let hasPrevious: Bool
    private let hasNext: Bool

    /// 是否全屏。
    private let isFullScreen: Bool

    /// 是否提供 PiP（引擎没有暴露 PiP API 时为 `false`，按钮禁用并给出说明）。
    private let isPiPAvailable: Bool

    /// 回调。
    private let onPrevious: () -> Void
    private let onNext: () -> Void
    private let onToggleFullScreen: () -> Void
    private let onTogglePiP: () -> Void

    /// 弹出层开关。
    @State private var showsVolume = false
    @State private var showsAudioMenu = false
    @State private var showsSubtitleMenu = false
    @State private var showsRateMenu = false

    /// 可选倍速。
    private static let rates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    /// 创建控制条。
    ///
    /// - Parameters:
    ///   - model: 播放器视图模型。
    ///   - hasPrevious: 是否有上一集。
    ///   - hasNext: 是否有下一集。
    ///   - isFullScreen: 是否全屏。
    ///   - isPiPAvailable: 是否提供画中画。
    ///   - onPrevious: 上一集回调。
    ///   - onNext: 下一集回调。
    ///   - onToggleFullScreen: 全屏切换回调。
    ///   - onTogglePiP: 画中画回调。
    public init(
        model: PlayerViewModel,
        hasPrevious: Bool = false,
        hasNext: Bool = false,
        isFullScreen: Bool = false,
        isPiPAvailable: Bool = false,
        onPrevious: @escaping () -> Void = {},
        onNext: @escaping () -> Void = {},
        onToggleFullScreen: @escaping () -> Void = {},
        onTogglePiP: @escaping () -> Void = {}
    ) {
        self.model = model
        self.hasPrevious = hasPrevious
        self.hasNext = hasNext
        self.isFullScreen = isFullScreen
        self.isPiPAvailable = isPiPAvailable
        self.onPrevious = onPrevious
        self.onNext = onNext
        self.onToggleFullScreen = onToggleFullScreen
        self.onTogglePiP = onTogglePiP
    }

    public var body: some View {
        VStack(spacing: Spacing.xs) {
            ProgressSlider(
                position: model.position,
                duration: model.duration,
                buffered: model.buffered,
                isIndeterminate: !model.hasDuration,
                isEnabled: model.hasDuration && !model.hasFailed,
                onScrubbingChanged: { isScrubbing in
                    if isScrubbing {
                        model.beginScrubbing()
                    } else {
                        model.endScrubbing()
                    }
                },
                onSeek: { target in
                    Task { await model.seek(to: target) }
                }
            )

            controlsRow
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.md)
        .background {
            // 底部渐变：保证控制条在明亮画面上也能看清（HIG 的对比度要求）。
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.55), .black.opacity(0.78)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        }
        // 弹层展开时钉住控制条：否则用户正在挑字幕，控制条连同弹层一起淡出。
        .onChange(of: showsVolume) { _, _ in updatePinning() }
        .onChange(of: showsAudioMenu) { _, _ in updatePinning() }
        .onChange(of: showsSubtitleMenu) { _, _ in updatePinning() }
        .onChange(of: showsRateMenu) { _, _ in updatePinning() }
    }

    /// 把「是否有弹层展开」同步给视图模型。
    private func updatePinning() {
        model.setControlsPinned(showsVolume || showsAudioMenu || showsSubtitleMenu || showsRateMenu)
    }

    // MARK: - 控制行

    /// 一行控制：左侧播放控制、中间时间、右侧开关与菜单。
    private var controlsRow: some View {
        ZStack {
            HStack(spacing: Spacing.xs) {
                playbackButtons
                Spacer(minLength: Spacing.lg)
                trailingButtons
            }

            timeDisplay
        }
        .frame(height: 32)
    }

    /// 左侧：播放 / 暂停、上一集、下一集。
    private var playbackButtons: some View {
        HStack(spacing: Spacing.xs) {
            PrismIconButton(
                systemImage: model.isPlaying ? "pause.fill" : "play.fill",
                accessibilityLabel: model.isPlaying ? "暂停（空格）" : "播放（空格）"
            ) {
                Task { await model.togglePlayPause() }
            }

            PrismIconButton(systemImage: "backward.end.fill", accessibilityLabel: "上一集（⌘←）") {
                onPrevious()
            }
            .disabled(!hasPrevious)

            PrismIconButton(systemImage: "forward.end.fill", accessibilityLabel: "下一集（⌘→）") {
                onNext()
            }
            .disabled(!hasNext)
        }
        .foregroundStyle(.white)
    }

    /// 中间：当前时间 / 总时长。
    ///
    /// 时长未知时显示 `--:--`（坑 1：起播瞬间引擎还没有时长，不能显示 `00:00` 骗人）。
    private var timeDisplay: some View {
        HStack(spacing: Spacing.xs) {
            Text(model.position.formatted)
                .foregroundStyle(.white)

            Text("/")
                .foregroundStyle(.white.opacity(0.45))

            Text(model.hasDuration ? model.duration.formatted : "--:--")
                .foregroundStyle(.white.opacity(0.65))
        }
        .font(Typography.monoTime)
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("播放时间"))
        .accessibilityValue(
            Text(model.hasDuration
                ? "\(model.position.formatted) / \(model.duration.formatted)"
                : "\(model.position.formatted)，总时长未知")
        )
    }

    /// 右侧：音量、音轨、字幕、倍速、PiP、全屏。
    private var trailingButtons: some View {
        HStack(spacing: Spacing.xs) {
            volumeButton
            audioButton
            subtitleButton
            rateButton

            PrismIconButton(systemImage: "pip", accessibilityLabel: "画中画") {
                onTogglePiP()
            }
            .disabled(!isPiPAvailable)
            .help(isPiPAvailable ? "画中画" : "当前引擎未暴露画中画接口")

            PrismIconButton(
                systemImage: isFullScreen
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right",
                accessibilityLabel: isFullScreen ? "退出全屏（Esc）" : "进入全屏（F）"
            ) {
                onToggleFullScreen()
            }
        }
        .foregroundStyle(.white)
    }

    // MARK: - 音量

    /// 音量按钮：点击展开音量滑杆（含静音开关）。
    ///
    /// 静音由 `M` 键或弹层里的开关完成；点击图标本身不直接静音——那会让
    /// 「想调音量」的用户误触成静音。
    private var volumeButton: some View {
        PrismIconButton(
            systemImage: volumeSystemImage,
            accessibilityLabel: model.isMuted ? "音量（已静音，M 取消静音）" : "音量（M 静音）"
        ) {
            showsVolume.toggle()
        }
        .popover(isPresented: $showsVolume, arrowEdge: .bottom) {
            volumePopover
        }
        .contextMenu {
            Button(model.isMuted ? "取消静音" : "静音") { Task { await model.toggleMute() } }
            Button("音量 +5%") { Task { await model.adjustVolume(by: 0.05) } }
            Button("音量 −5%") { Task { await model.adjustVolume(by: -0.05) } }
        }
    }

    /// 音量图标随音量变化（0 / 低 / 中 / 高）。
    private var volumeSystemImage: String {
        if model.isMuted || model.volume <= 0 {
            return "speaker.slash.fill"
        }
        if model.volume < 0.34 {
            return "speaker.fill"
        }
        if model.volume < 0.67 {
            return "speaker.wave.1.fill"
        }
        return "speaker.wave.2.fill"
    }

    /// 音量弹层。
    private var volumePopover: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "speaker.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { model.volume },
                        set: { value in Task { await model.setVolume(value) } }
                    ),
                    in: 0...1
                )
                .frame(width: 140)
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: Spacing.sm) {
                Button(model.isMuted ? "取消静音" : "静音") {
                    Task { await model.toggleMute() }
                }
                .buttonStyle(.link)
                .font(Typography.caption)

                Spacer(minLength: Spacing.sm)

                Text("\(Int((model.volume * 100).rounded()))%")
                    .font(Typography.monoTime)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Spacing.md)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("音量"))
    }

    // MARK: - 音轨

    /// 音轨按钮。
    private var audioButton: some View {
        PrismIconButton(systemImage: "waveform", accessibilityLabel: "音轨（A 循环切换）") {
            showsAudioMenu.toggle()
        }
        .popover(isPresented: $showsAudioMenu, arrowEdge: .bottom) {
            AudioTrackMenu(
                tracks: model.audioTrackItems,
                selectedIndex: model.selectedAudioIndex,
                onSelect: { index in
                    showsAudioMenu = false
                    Task { await model.selectAudioTrack(index) }
                }
            )
        }
    }

    // MARK: - 字幕

    /// 字幕按钮。
    private var subtitleButton: some View {
        PrismIconButton(
            systemImage: model.selectedSubtitleIndex == nil ? "captions.bubble" : "captions.bubble.fill",
            accessibilityLabel: "字幕（S 开关）"
        ) {
            showsSubtitleMenu.toggle()
        }
        .popover(isPresented: $showsSubtitleMenu, arrowEdge: .bottom) {
            SubtitleTrackMenu(
                tracks: model.subtitleTrackItems,
                selectedIndex: model.selectedSubtitleIndex,
                delay: model.subtitleDelay,
                onSelect: { index in
                    showsSubtitleMenu = false
                    Task { await model.selectSubtitleTrack(index) }
                },
                onAdjustDelay: { delta in
                    Task { await model.adjustSubtitleDelay(by: delta) }
                },
                onResetDelay: {
                    Task { await model.resetSubtitleDelay() }
                }
            )
        }
    }

    // MARK: - 倍速

    /// 倍速按钮。
    private var rateButton: some View {
        PrismIconButton(systemImage: "speedometer", accessibilityLabel: "播放速度（> / < 调整）") {
            showsRateMenu.toggle()
        }
        .popover(isPresented: $showsRateMenu, arrowEdge: .bottom) {
            ratePopover
        }
    }

    /// 倍速弹层。
    private var ratePopover: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("播放速度")
                .font(Typography.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.sm)
                .padding(.bottom, Spacing.xs)

            ForEach(Self.rates, id: \.self) { rate in
                Button {
                    showsRateMenu = false
                    Task { await model.setRate(rate) }
                } label: {
                    HStack {
                        Text(rateLabel(rate))
                            .font(Typography.body)
                        Spacer(minLength: Spacing.lg)
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.accent)
                            .opacity(abs(model.rate - rate) < 0.001 ? 1 : 0)
                    }
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Spacing.md)
        .frame(width: 180)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("播放速度"))
    }

    /// 倍速文案：`1×` / `1.5×`。
    ///
    /// - Parameter rate: 倍速。
    /// - Returns: 展示文案。
    private func rateLabel(_ rate: Double) -> String {
        guard rate != rate.rounded() else { return "\(Int(rate))×" }
        return String(format: "%.2f×", rate).replacingOccurrences(of: "0×", with: "×")
    }
}

// MARK: - 预览

/// 控制条预览板：播放中 / 暂停 / 时长未知。
private struct PlayerControlsPreviewBoard: View {
    var body: some View {
        VStack(spacing: Spacing.xxl) {
            section("播放中（时长已知）") { PlayerControls(model: PlayerPreviewModel.playing()) }
            section("暂停") { PlayerControls(model: PlayerPreviewModel.paused()) }
            section("起播（坑 1：时长未知）") { PlayerControls(model: PlayerPreviewModel.loading()) }
        }
        .padding(.vertical, Spacing.xxl)
        .frame(width: 820)
        .background(
            LinearGradient(colors: [.black, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
        )
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title)
                .font(Typography.caption)
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, Spacing.lg)
            content()
        }
    }
}

#Preview("PlayerControls · 深色") {
    PlayerControlsPreviewBoard()
        .prismTheme(PrismTheme(appearance: .dark))
}
