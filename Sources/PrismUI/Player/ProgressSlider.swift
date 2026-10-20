import PrismCore
import SwiftUI

// MARK: - 进度条

/// 播放器底部的进度条。
///
/// 三段时间轴叠在一起绘制：**已播**（强调色）、**缓冲**（半透明白）、
/// **未缓冲**（更淡的白）。所有颜色都用白色系而不是 ``Palette`` 的语义色，
/// 因为播放器永远压在黑色视频画面上，语义色在深色外观下会与视频混在一起。
///
/// 交互：
/// - 悬停：显示该位置的时间气泡（v1.0 没有 trickplay 缩略图，见
///   `docs/research/ux-benchmark.md` §3.13；v1.1 接 trickplay 时把气泡换成
///   「缩略图 + 时间」即可，位置计算不需要改）；
/// - 按下并拖动：**拖拽期间进度条只跟随手指**，不跟随播放进度——否则会出现
///   「拽着拽着跳回去」（`docs/ARCHITECTURE.md` §3.5 坑 2 的同一类问题）；
/// - 松开：回调 ``onSeek`` 提交目标位置。
///
/// **不确定态**（``isIndeterminate``）：`duration` 还是 0 时（起播瞬间，
/// 见 `docs/ARCHITECTURE.md` §3.5 坑 1）不画已播段，只留一条呼吸的细轨道，
/// 避免出现「00:00 / 00:00」的假进度。
public struct ProgressSlider: View {
    /// 当前播放位置。
    private let position: Ticks
    /// 总时长；为 0 表示引擎还没给出时长。
    private let duration: Ticks
    /// 已缓冲到的位置。
    private let buffered: Ticks
    /// 是否处于「时长未知」的不确定态。
    private let isIndeterminate: Bool
    /// 是否可交互（加载中 / 错误时禁用）。
    private let isEnabled: Bool
    /// 拖拽开始 / 结束通知；视图模型据此冻结或解冻进度更新。
    private let onScrubbingChanged: (Bool) -> Void
    /// 提交跳转位置。
    private let onSeek: (Ticks) -> Void

    /// 鼠标悬停位置（0...1）；`nil` 表示鼠标不在进度条上。
    @State private var hoverFraction: Double?
    /// 拖拽位置（0...1）；`nil` 表示没有在拖拽。
    @State private var dragFraction: Double?
    /// 是否正在拖拽（用于区分「悬停」与「拖拽」两种气泡行为）。
    @State private var isScrubbing = false
    /// 不确定态的呼吸动画开关。
    @State private var isPulsing = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 进度条的几何常量。
    private enum Metrics {
        /// 常规轨道高度。
        static let trackHeight: CGFloat = 4
        /// 悬停 / 拖拽时轨道高度（给「加粗反馈」）。
        static let activeTrackHeight: CGFloat = 6
        /// 滑块直径。
        static let knobDiameter: CGFloat = 11
        /// 整条控件的可点击高度（远大于视觉轨道，符合 44pt 触达区的思路）。
        static let hitHeight: CGFloat = 24
        /// 时间气泡与轨道之间的间距。
        static let previewGap: CGFloat = 8
        /// 时间气泡的内边距。
        static let previewPadding: CGFloat = 6
    }

    /// 创建进度条。
    ///
    /// - Parameters:
    ///   - position: 当前播放位置。
    ///   - duration: 总时长；0 表示未知。
    ///   - buffered: 已缓冲位置。
    ///   - isIndeterminate: 是否显示不确定态（时长未知）。
    ///   - isEnabled: 是否可交互。
    ///   - onScrubbingChanged: 拖拽开始 / 结束回调（`true` = 开始）。
    ///   - onSeek: 松开时提交的目标位置。
    public init(
        position: Ticks,
        duration: Ticks,
        buffered: Ticks,
        isIndeterminate: Bool = false,
        isEnabled: Bool = true,
        onScrubbingChanged: @escaping (Bool) -> Void = { _ in },
        onSeek: @escaping (Ticks) -> Void = { _ in }
    ) {
        self.position = position
        self.duration = duration
        self.buffered = buffered
        self.isIndeterminate = isIndeterminate
        self.isEnabled = isEnabled
        self.onScrubbingChanged = onScrubbingChanged
        self.onSeek = onSeek
    }

    // MARK: - 派生值

    /// 总时长是否可用。
    private var hasDuration: Bool {
        duration.rawValue > 0 && !isIndeterminate
    }

    /// 当前应显示的进度比例（0...1）。
    ///
    /// 拖拽中优先用拖拽位置——这正是「拖拽不跟随播放进度」的实现点。
    private var displayedFraction: Double {
        if let dragFraction { return dragFraction }
        return fraction(of: position)
    }

    /// 缓冲比例（0...1）。
    private var bufferedFraction: Double {
        guard hasDuration else { return 0 }
        return fraction(of: buffered)
    }

    /// 是否处于「激活」外观（悬停或拖拽）。
    private var isActive: Bool {
        isScrubbing || hoverFraction != nil
    }

    /// 气泡要显示的位置：拖拽优先，其次悬停。
    private var previewFraction: Double? {
        if isScrubbing, let dragFraction { return dragFraction }
        return hoverFraction
    }

    /// 把 tick 换算成 0...1。
    ///
    /// - Parameter value: 位置。
    /// - Returns: 比例，钳到 `0...1`。
    private func fraction(of value: Ticks) -> Double {
        guard hasDuration else { return 0 }
        let raw = value.seconds / duration.seconds
        guard raw.isFinite else { return 0 }
        return min(max(raw, 0), 1)
    }

    /// 把比例钳到 `0...1`。
    ///
    /// - Parameter value: 原始比例。
    /// - Returns: 钳制后的比例。
    private func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    // MARK: - 视图

    public var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)

            ZStack(alignment: .leading) {
                track
            }
            .frame(width: width, height: Metrics.hitHeight)
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case let .active(point):
                    hoverFraction = clamp(point.x / width)
                case .ended:
                    hoverFraction = nil
                }
            }
            .gesture(dragGesture(width: width))
            .overlay(alignment: .topLeading) {
                previewBubble(width: width)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: Motion.quick), value: isActive)
        }
        .frame(height: Metrics.hitHeight)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("播放进度"))
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            guard hasDuration else { return }
            switch direction {
            case .increment:
                onSeek(min(position + Ticks(seconds: 5), duration))
            case .decrement:
                onSeek(max(position - Ticks(seconds: 5), .zero))
            @unknown default:
                break
            }
        }
        .task(id: isIndeterminate) {
            // 不确定态用「呼吸」表达「正在等待时长」，尊重「减弱动态效果」。
            guard isIndeterminate, !reduceMotion else {
                isPulsing = false
                return
            }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }

    /// 轨道本体：底轨 + 缓冲段 + 已播段 + 滑块。
    private var track: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let height = isActive ? Metrics.activeTrackHeight : Metrics.trackHeight
            let playedWidth = width * displayedFraction
            let bufferedWidth = width * bufferedFraction

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(isIndeterminate ? 0.22 : 0.20))

                if hasDuration {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.34))
                        .frame(width: bufferedWidth)

                    Capsule(style: .continuous)
                        .fill(Palette.accent)
                        .frame(width: playedWidth)
                } else if isPulsing {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.30))
                }

                if hasDuration {
                    Circle()
                        .fill(Color.white)
                        .frame(width: Metrics.knobDiameter, height: Metrics.knobDiameter)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .offset(x: min(max(playedWidth - Metrics.knobDiameter / 2, 0), max(width - Metrics.knobDiameter, 0)))
                        .opacity(isActive ? 1 : 0)
                }
            }
            .frame(width: width, height: height)
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .allowsHitTesting(false)
    }

    /// 时间气泡：悬停 / 拖拽时显示「该位置的时间」。
    ///
    /// v1.0 没有 trickplay 缩略图，因此气泡只有时间文本（UX 文档 §3.13 的降级形态）。
    /// 左右两侧会被钳制在轨道范围内，避免气泡超出窗口。
    @ViewBuilder
    private func previewBubble(width: CGFloat) -> some View {
        if let previewFraction, hasDuration {
            let seconds = previewFraction * duration.seconds
            let label = Ticks(seconds: seconds).formatted

            Text(label)
                .font(Typography.monoTime)
                .foregroundStyle(.white)
                .padding(.horizontal, Metrics.previewPadding + 2)
                .padding(.vertical, Metrics.previewPadding)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.black.opacity(0.82))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                        }
                }
                .fixedSize()
                .offset(x: bubbleOffset(fraction: previewFraction, width: width), y: -30)
                .transition(.opacity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// 计算气泡的横向偏移，让它始终落在轨道内。
    ///
    /// - Parameters:
    ///   - fraction: 气泡锚点比例。
    ///   - width: 轨道宽度。
    /// - Returns: 横向偏移（pt）。
    private func bubbleOffset(fraction: Double, width: CGFloat) -> CGFloat {
        // 气泡宽度由文本决定，这里按 7 个字符的典型宽度估算，再钳到轨道内。
        let estimatedWidth: CGFloat = 58
        let center = width * fraction
        return min(max(center - estimatedWidth / 2, 0), max(width - estimatedWidth, 0))
    }

    /// 拖拽手势：按下即开始，拖动只改本地状态，松手才提交。
    ///
    /// - Parameter width: 轨道宽度。
    /// - Returns: 手势。
    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard isEnabled, hasDuration else { return }
                if !isScrubbing {
                    isScrubbing = true
                    onScrubbingChanged(true)
                }
                dragFraction = clamp(value.location.x / width)
            }
            .onEnded { value in
                guard isEnabled, hasDuration else { return }
                let target = clamp(value.location.x / width)
                dragFraction = nil
                isScrubbing = false
                onScrubbingChanged(false)
                onSeek(Ticks(seconds: target * duration.seconds))
            }
    }

    /// VoiceOver 读出的值：「当前 / 总长」。
    private var accessibilityValue: Text {
        guard hasDuration else { return Text("时长未知") }
        return Text("\(position.formatted) / \(duration.formatted)")
    }
}

// MARK: - 预览

/// 进度条预览板：正常 / 不确定态 / 禁用。
private struct ProgressSliderPreviewBoard: View {
    @State private var position = Ticks(seconds: 754)
    @State private var scrubbing = false

    private let duration = Ticks(seconds: 6130)

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            row("正常（已播 12:34 / 缓冲 40:00）") {
                ProgressSlider(
                    position: position,
                    duration: duration,
                    buffered: Ticks(seconds: 2400),
                    onScrubbingChanged: { scrubbing = $0 },
                    onSeek: { position = $0 }
                )
            }

            row("不确定态（坑 1：duration 仍为 0）") {
                ProgressSlider(
                    position: .zero,
                    duration: .zero,
                    buffered: .zero,
                    isIndeterminate: true
                )
            }

            row("禁用") {
                ProgressSlider(
                    position: position,
                    duration: duration,
                    buffered: Ticks(seconds: 2400),
                    isEnabled: false
                )
            }

            Text("悬停进度条可看到时间气泡；拖动时气泡跟随手指。")
                .font(Typography.caption)
                .foregroundStyle(.white.opacity(0.6))

            Text(scrubbing ? "正在拖拽（进度更新应被冻结）" : "未拖拽")
                .font(Typography.caption)
                .foregroundStyle(.white.opacity(0.6))

            Spacer(minLength: 0)
        }
        .padding(Spacing.xxl)
        .frame(width: 720, height: 400, alignment: .topLeading)
        .background(.black)
    }

    private func row(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title)
                .font(Typography.caption)
                .foregroundStyle(.white.opacity(0.6))
            content()
        }
    }
}

#Preview("ProgressSlider · 播放器暗色") {
    ProgressSliderPreviewBoard()
        .prismTheme(PrismTheme(appearance: .dark))
}
