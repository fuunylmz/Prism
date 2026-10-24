import AppKit
import PrismCore
import PrismPlayback
import SwiftUI

// MARK: - 播放器页面

/// 全窗口播放页（v1.0 的播放器形态）。
///
/// 结构（`docs/research/ux-benchmark.md` §3.10）：
///
/// ```
/// ┌──────────────────────────────────────────────────────────────┐
/// │ ‹ 返回   剧名 · S01E02 · 集名                                 │  ← 顶部条（随控制条隐藏）
/// │                                                              │
/// │                    引擎渲染面（renderView）                    │
/// │             加载菊花 / 缓冲转圈 / 错误态（居中覆盖）              │
/// │                                                              │
/// │ ▶ ⏮ ⏭        12:34 / 1:42:10      🔊 音轨 字幕 倍速 PiP ⛶    │  ← 控制条（3s 自动隐藏）
/// └──────────────────────────────────────────────────────────────┘
/// ```
///
/// 行为要点：
/// - 视频画面由引擎的 `renderView` 铺满窗口，本视图只负责叠层；
/// - **鼠标 3 秒不动自动隐藏**控制条与顶部条（``Motion/standard`` 淡出）；
///   暂停 / 缓冲 / 出错 / 拖拽 / 菜单展开时保持显示（由 ``PlayerViewModel`` 判定）；
/// - 单击画面播放 / 暂停，双击切换全屏；
/// - `Esc` 退出全屏（全屏时）；不在全屏时交给外壳关闭播放器；
/// - 键盘映射见 ``PlayerKeyboardMap``（ux-benchmark §4.6）。
///
/// 播放器始终以**暗色**渲染（视频画面背景），因此这里显式注入
/// `colorScheme = .dark`：设计系统的语义色在浅色外观下会变成深色文字，
/// 叠在黑色视频上会看不见。
public struct PlayerView: View {
    /// 视图模型。
    private let model: PlayerViewModel

    /// 主标题（剧集显示「剧名 · S01E02 · 集名」）。
    private let title: String
    /// 副标题（集名 / 版本信息），可选。
    private let subtitle: String?

    /// 是否有上一集 / 下一集。
    private let hasPrevious: Bool
    private let hasNext: Bool

    /// 回调。
    private let onBack: () -> Void
    private let onPrevious: () -> Void
    private let onNext: () -> Void
    private let onRetry: () -> Void
    private let onTogglePiP: (() -> Void)?

    /// 是否全屏（由窗口通知回写）。
    @State private var isFullScreen = false

    @Bindable private var subtitleSettings: AppSettings

    /// 键盘焦点。
    @FocusState private var isKeyboardFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 创建播放器页面。
    ///
    /// - Parameters:
    ///   - model: 播放器视图模型（需已 `attach(engine:)`）。
    ///   - title: 主标题；剧集建议传「剧名 · S01E02 · 集名」。
    ///   - subtitle: 副标题，可选。
    ///   - hasPrevious: 是否有上一集（决定 `⌘←` 与按钮是否可用）。
    ///   - hasNext: 是否有下一集（决定 `⌘→` 与按钮是否可用）。
    ///   - onBack: 返回 / 关闭播放器。
    ///   - onPrevious: 上一集。
    ///   - onNext: 下一集。
    ///   - onRetry: 失败后重试。
    ///   - onTogglePiP: 画中画；`nil` 表示当前引擎不提供，按钮禁用。
    public init(
        model: PlayerViewModel,
        title: String,
        subtitle: String? = nil,
        hasPrevious: Bool = false,
        hasNext: Bool = false,
        onBack: @escaping () -> Void = {},
        onPrevious: @escaping () -> Void = {},
        onNext: @escaping () -> Void = {},
        onRetry: @escaping () -> Void = {},
        onTogglePiP: (() -> Void)? = nil
    ) {
        self.model = model
        self.title = title
        self.subtitle = subtitle
        self.hasPrevious = hasPrevious
        self.hasNext = hasNext
        self.onBack = onBack
        self.onPrevious = onPrevious
        self.onNext = onNext
        self.onRetry = onRetry
        self.onTogglePiP = onTogglePiP
        self._subtitleSettings = Bindable(wrappedValue: .shared)
    }

    public var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            engineSurface
                .ignoresSafeArea()
                .contentShape(Rectangle())
                // 单击 = 播放/暂停，双击 = 全屏（UX 文档 §3.10）。
                //
                // 用 `ExclusiveGesture` 显式表达「双击优先」，而不是叠两个
                // `.onTapGesture`：后者在双击的第一下就会触发单击动作，
                // 表现为「双击全屏时画面先暂停一下」。
                .gesture(
                    ExclusiveGesture(
                        TapGesture(count: 2).onEnded { toggleFullScreen() },
                        TapGesture(count: 1).onEnded {
                            model.noteUserActivity()
                            Task { await model.togglePlayPause() }
                        }
                    )
                )

            SubtitleOverlay(
                cues: model.subtitleCues,
                position: model.position,
                settings: subtitleSettings
            )

            centerOverlay

            chrome
        }
        .environment(\.colorScheme, .dark)
        .onContinuousHover(coordinateSpace: .local) { _ in
            // 鼠标移动即「有操作」：显示控制条并重新计时。
            model.noteUserActivity()
        }
        .focusable()
        .focused($isKeyboardFocused)
        .focusEffectDisabled()
        .playerKeyboard(
            model,
            isFullScreen: isFullScreen,
            onToggleFullScreen: { toggleFullScreen() },
            canGoPrevious: hasPrevious,
            canGoNext: hasNext,
            onPrevious: onPrevious,
            onNext: onNext
        )
        .onExitCommand {
            // Esc 三级回退的第一级：退出全屏；不在全屏时才关闭播放器（§4.6 第 30 条）。
            if isFullScreen {
                toggleFullScreen()
            } else {
                onBack()
            }
        }
        .background {
            WindowFullScreenObserver { fullScreen in
                isFullScreen = fullScreen
            }
            .frame(width: 0, height: 0)
        }
        .task {
            isKeyboardFocused = true
            model.noteUserActivity()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("播放器"))
    }

    // MARK: - 引擎渲染面

    /// 引擎提供的渲染面；`nil` 时显示占位（预览 / 引擎尚未 attach）。
    ///
    /// 协议返回的是 `AnyView`（适配器内部已经把 `AVPlayerLayer` / `CAMetalLayer` 绑好），
    /// 播放器只负责把它铺满窗口，不碰任何图层。
    @ViewBuilder
    private var engineSurface: some View {
        if let renderView = model.renderView {
            renderView
        } else {
            ZStack {
                Color.black
                Text("等待播放引擎…")
                    .font(Typography.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .accessibilityHidden(true)
        }
    }

    // MARK: - 顶部条 + 控制条

    /// 顶部条与控制条：两者同生同灭，一起淡出。
    private var chrome: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            PlayerControls(
                model: model,
                hasPrevious: hasPrevious,
                hasNext: hasNext,
                isFullScreen: isFullScreen,
                isPiPAvailable: onTogglePiP != nil,
                onPrevious: onPrevious,
                onNext: onNext,
                onToggleFullScreen: { toggleFullScreen() },
                onTogglePiP: { onTogglePiP?() }
            )
        }
        .opacity(model.isControlsVisible ? 1 : 0)
        .allowsHitTesting(model.isControlsVisible)
        .animation(reduceMotion ? nil : .easeInOut(duration: Motion.standard), value: model.isControlsVisible)
    }

    /// 顶部条：返回 + 标题。
    private var topBar: some View {
        HStack(alignment: .center, spacing: Spacing.sm) {
            PrismIconButton(systemImage: "chevron.left", accessibilityLabel: "返回（Esc）") {
                onBack()
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Typography.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Typography.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: Spacing.sm)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.xl)
        .background {
            LinearGradient(
                colors: [.black.opacity(0.72), .black.opacity(0.32), .black.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        }
    }

    // MARK: - 中央状态

    /// 中央覆盖层：加载 / 缓冲 / 错误 / 播放结束。
    @ViewBuilder
    private var centerOverlay: some View {
        switch model.state {
        case .loading:
            loadingOverlay

        case .buffering:
            if model.isBufferingVisible {
                bufferingOverlay
            }

        case let .failed(failure):
            errorOverlay(failure)

        case .ended:
            endedOverlay

        case .idle, .playing, .paused:
            EmptyView()
        }
    }

    /// 起播加载：菊花 + 文案 + 取消。
    private var loadingOverlay: some View {
        VStack(spacing: Spacing.md) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)

            Text("正在准备播放…")
                .font(Typography.body)
                .foregroundStyle(.white.opacity(0.85))

            Button("取消") {
                onBack()
            }
            .buttonStyle(.link)
            .font(Typography.caption)
            .accessibilityLabel("取消播放")
        }
        .padding(Spacing.xl)
        .background {
            RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
                .fill(.black.opacity(0.55))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("正在准备播放"))
    }

    /// 缓冲：只在超过 1 秒后出现，避免每次微缓冲都闪一下。
    private var bufferingOverlay: some View {
        VStack(spacing: Spacing.sm) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
            Text("正在缓冲…")
                .font(Typography.caption)
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .background {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(.black.opacity(0.5))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("正在缓冲"))
    }

    /// 播放结束：给出「下一集」出口。
    private var endedOverlay: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.white.opacity(0.85))
                .accessibilityHidden(true)

            Text("播放结束")
                .font(Typography.title)
                .foregroundStyle(.white)

            if hasNext {
                PrismPrimaryButton("下一集", systemImage: "forward.end.fill") {
                    onNext()
                }
            }
        }
        .padding(Spacing.xl)
        .background {
            RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
                .fill(.black.opacity(0.6))
        }
    }

    /// 错误态：图标 + 标题 + 原因 + 重试 / 返回。
    ///
    /// 文案按 ux-benchmark §3.10 的错误表：说清「发生了什么」+ 给一个可执行的下一步。
    ///
    /// - Parameter failure: 引擎给出的失败原因。
    /// - Returns: 错误覆盖层。
    private func errorOverlay(_ failure: PlaybackFailure) -> some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.white.opacity(0.85))
                .accessibilityHidden(true)

            VStack(spacing: Spacing.xs) {
                Text("无法播放该文件")
                    .font(Typography.title)
                    .foregroundStyle(.white)

                Text(PlayerFailureText.message(for: failure))
                    .font(Typography.body)
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
            }

            HStack(spacing: Spacing.md) {
                PrismSecondaryButton("返回") {
                    onBack()
                }

                PrismPrimaryButton("重试", systemImage: "arrow.clockwise") {
                    onRetry()
                }
            }
        }
        .padding(Spacing.xxl)
        .background {
            RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
                .fill(.black.opacity(0.72))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("无法播放该文件"))
    }

    // MARK: - 全屏

    /// 切换窗口全屏。
    ///
    /// 用标准的 `toggleFullScreen(_:)`（HIG 的 `⌃⌘F` 同一条路径），
    /// 而不是自己改窗口尺寸——这样才进得了系统全屏空间、菜单栏与 Dock 才会自动隐藏。
    private func toggleFullScreen() {
        model.noteUserActivity()
        NSApp.keyWindow?.toggleFullScreen(nil)
    }
}

/// 观察宿主窗口的全屏状态。
///
/// SwiftUI 没有暴露窗口全屏状态，而按钮图标与 `Esc` 的语义都依赖它。
/// 这里用 `NSView` 的生命周期 + `NotificationCenter` 的选择器式监听：
/// 选择器式 API 不跨并发域传闭包，在 Swift 6 严格并发下没有 `Sendable` 问题。
private struct WindowFullScreenObserver: NSViewRepresentable {
    /// 状态变化回调。
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onChange = onChange
        nsView.reportCurrentState()
    }

    /// 实际的监听者。
    final class ObserverView: NSView {
        /// 状态变化回调。
        var onChange: ((Bool) -> Void)?

        /// 当前是否已注册通知。
        private var isObserving = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            registerObserversIfNeeded()
            reportCurrentState()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                unregisterObservers()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        /// 把当前全屏状态回写一次。
        func reportCurrentState() {
            let isFullScreen = window?.styleMask.contains(.fullScreen) ?? false
            onChange?(isFullScreen)
        }

        /// 注册进入 / 退出全屏通知（只注册一次）。
        private func registerObserversIfNeeded() {
            guard let window, !isObserving else { return }
            isObserving = true
            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(windowDidToggleFullScreen(_:)),
                name: NSWindow.didEnterFullScreenNotification,
                object: window
            )
            center.addObserver(
                self,
                selector: #selector(windowDidToggleFullScreen(_:)),
                name: NSWindow.didExitFullScreenNotification,
                object: window
            )
        }

        /// 注销通知。
        private func unregisterObservers() {
            guard isObserving else { return }
            isObserving = false
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didEnterFullScreenNotification,
                object: nil
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didExitFullScreenNotification,
                object: nil
            )
        }

        /// 通知回调。
        ///
        /// - Parameter notification: 全屏状态变化通知。
        @objc private func windowDidToggleFullScreen(_ notification: Notification) {
            reportCurrentState()
        }
    }
}

// MARK: - 失败原因文案

/// 把 ``PrismPlayback/PlaybackFailure`` 翻译成一句中文说明。
///
/// 文案对齐 ux-benchmark §3.10 的错误表：**说清原因 + 不吓人**，
/// 具体的技术细节留给日志（用户看不懂 codec 名）。
enum PlayerFailureText {
    /// 失败原因对应的中文说明。
    ///
    /// 按 ``PrismPlayback/PlaybackFailure/kind`` 分支，**不**直接展示引擎的
    /// `message`：那是给日志看的（可能夹着 AVFoundation 的英文报错）。
    ///
    /// - Parameter failure: 引擎给出的失败原因。
    /// - Returns: 一句中文说明。
    static func message(for failure: PlaybackFailure) -> String {
        switch failure.kind {
        case .load:
            "无法打开这个文件，可能是服务器拒绝或地址已失效。"
        case .network:
            "连接已中断，请检查网络后重试。"
        case .unsupportedMedia:
            "这个文件用了不支持的编码或容器，换个版本试试。"
        case .decode:
            "解码失败，文件可能已损坏。"
        case .cancelled:
            "播放已取消。"
        case .unknown:
            "发生了未知错误，请重试或换个版本。"
        }
    }
}

// MARK: - 预览

/// 预览宿主：给播放器一个固定 16:9 的画布。
private struct PlayerPreviewHost: View {
    let model: PlayerViewModel
    let title: String
    let subtitle: String?

    init(model: PlayerViewModel, title: String = "人生切割术 · S01E02 · 半环", subtitle: String? = "4K · HDR · 直通") {
        self.model = model
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        PlayerView(
            model: model,
            title: title,
            subtitle: subtitle,
            hasPrevious: true,
            hasNext: true,
            onTogglePiP: {}
        )
        .frame(width: 960, height: 540)
    }
}

#Preview("播放中") {
    PlayerPreviewHost(model: PlayerPreviewModel.playing())
        .prismTheme(PrismTheme(appearance: .dark))
}

#Preview("暂停") {
    PlayerPreviewHost(model: PlayerPreviewModel.paused())
        .prismTheme(PrismTheme(appearance: .dark))
}

#Preview("缓冲中") {
    PlayerPreviewHost(model: PlayerPreviewModel.buffering())
        .prismTheme(PrismTheme(appearance: .dark))
}

#Preview("错误") {
    PlayerPreviewHost(model: PlayerPreviewModel.failed())
        .prismTheme(PrismTheme(appearance: .dark))
}

#Preview("控制条已隐藏") {
    PlayerPreviewHost(model: PlayerPreviewModel.controlsHidden())
        .prismTheme(PrismTheme(appearance: .dark))
}

#Preview("起播加载") {
    PlayerPreviewHost(model: PlayerPreviewModel.loading())
        .prismTheme(PrismTheme(appearance: .light))
}
