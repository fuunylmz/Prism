import SwiftUI

// MARK: - 主按钮

/// 主按钮：强调色填充，用于「播放 / 确认 / 重试」等**每屏唯一**的主操作。
///
/// 支持：
/// - `.disabled(...)`：整体降透明度，符合 HIG 的禁用态；
/// - 键盘焦点环：`.focusable()` + 自绘 2pt 强调色描边（隐藏系统默认焦点效果，
///   避免与自定义样式叠加出双层边框）。
///
/// 文字颜色会按强调色的亮度自动在黑/白之间选择：系统强调色可以被用户改成黄色等
/// 浅色，固定白字会失去对比度。
public struct PrismPrimaryButton: View {
    private let title: LocalizedStringKey
    private let systemImage: String?
    private let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.self) private var environment
    @FocusState private var isFocused: Bool
    @State private var isHovering = false

    /// 创建主按钮。
    ///
    /// - Parameters:
    ///   - title: 按钮文字（本地化 key）。
    ///   - systemImage: 左侧 SF Symbol，可选。
    ///   - action: 点击回调。
    public init(
        _ title: LocalizedStringKey,
        systemImage: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(title)
                    .font(Typography.headline)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, 7)
            .frame(minHeight: 30)
            .background {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Palette.accent)
                    .overlay {
                        // hover 时轻微提亮，不改变主色。
                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                            .fill(.white.opacity(isHovering ? 0.12 : 0))
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(PrismPressButtonStyle())
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: Motion.quick), value: isHovering)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .modifier(PrismFocusRing(isFocused: isFocused && isEnabled, cornerRadius: Radius.card))
        .opacity(isEnabled ? 1 : 0.45)
    }

    /// 强调色上的文字色。
    ///
    /// 用线性 sRGB 相对亮度做启发式判断：系统强调色可被用户改成黄色/绿色，
    /// 固定白字会失去对比度。阈值取 0.35（而不是 WCAG 黑白等对比点 0.179），
    /// 是为了让系统蓝/紫/红/粉仍保持惯用的白字，只把橙/黄/绿切到黑字。
    private var foreground: Color {
        let resolved = Palette.accent.resolve(in: environment)
        let luminance = 0.2126 * Double(resolved.linearRed)
            + 0.7152 * Double(resolved.linearGreen)
            + 0.0722 * Double(resolved.linearBlue)
        return luminance > 0.35 ? .black : .white
    }
}

// MARK: - 次按钮

/// 次按钮：描边 + 抬升表面，用于「取消 / 返回 / 次要操作」。
///
/// 与主按钮并排时形成清晰的主次层级；hover 只做轻微底色变化，不抢主按钮的注意力。
public struct PrismSecondaryButton: View {
    private let title: LocalizedStringKey
    private let systemImage: String?
    private let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var isHovering = false

    /// 创建次按钮。
    ///
    /// - Parameters:
    ///   - title: 按钮文字（本地化 key）。
    ///   - systemImage: 左侧 SF Symbol，可选。
    ///   - action: 点击回调。
    public init(
        _ title: LocalizedStringKey,
        systemImage: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(title)
                    .font(Typography.headline)
            }
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, 7)
            .frame(minHeight: 30)
            .background {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Palette.surfaceElevated)
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                            .fill(Palette.textPrimary.opacity(isHovering ? 0.08 : 0))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Palette.separator, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(PrismPressButtonStyle())
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: Motion.quick), value: isHovering)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .modifier(PrismFocusRing(isFocused: isFocused && isEnabled, cornerRadius: Radius.card))
        .opacity(isEnabled ? 1 : 0.45)
    }
}

// MARK: - 图标按钮

/// 图标按钮：无边框，hover 时出现圆形高亮底。
///
/// 用于工具栏、卡片浮层等空间紧张的位置。
/// **必须传 `accessibilityLabel`**：纯图标对 VoiceOver 不可读。
public struct PrismIconButton: View {
    private let systemImage: String
    private let accessibilityLabel: LocalizedStringKey
    private let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var isHovering = false

    /// 创建图标按钮。
    ///
    /// - Parameters:
    ///   - systemImage: SF Symbol 名。
    ///   - accessibilityLabel: 无障碍标签（也是 tooltip 文案）。
    ///   - action: 点击回调。
    public init(
        systemImage: String,
        accessibilityLabel: LocalizedStringKey,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 26, height: 26)
                .background {
                    Circle()
                        .fill(Palette.textPrimary.opacity(isHovering ? 0.10 : 0))
                }
                .contentShape(Circle())
        }
        .buttonStyle(PrismPressButtonStyle())
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: Motion.quick), value: isHovering)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .modifier(PrismFocusRing(isFocused: isFocused && isEnabled, cornerRadius: 13))
        .opacity(isEnabled ? 1 : 0.4)
        .help(accessibilityLabel)
        .accessibilityLabel(Text(accessibilityLabel))
    }
}

// MARK: - 内部样式

/// 统一的按压反馈：只改透明度，不做缩放（避免「减弱动态效果」下还要额外判断）。
private struct PrismPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

/// 自绘键盘焦点环。
///
/// 系统焦点效果被 `.focusEffectDisabled()` 关掉后，用 2pt 强调色描边代替，
/// 与 `docs/research/ux-benchmark.md` §5.1「焦点环用强调色」一致。
private struct PrismFocusRing: ViewModifier {
    let isFocused: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content.overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: cornerRadius + 2, style: .continuous)
                    .strokeBorder(Palette.accent, lineWidth: 2)
                    .padding(-3)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - 预览

private struct ButtonsPreviewBoard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            Text("Buttons").font(Typography.title)

            HStack(spacing: Spacing.md) {
                PrismPrimaryButton("播放", systemImage: "play.fill") {}
                PrismSecondaryButton("取消") {}
                PrismIconButton(systemImage: "heart", accessibilityLabel: "收藏") {}
            }

            HStack(spacing: Spacing.md) {
                PrismPrimaryButton("重试", systemImage: "arrow.clockwise") {}
                    .disabled(true)
                PrismSecondaryButton("返回") {}
                    .disabled(true)
                PrismIconButton(systemImage: "ellipsis", accessibilityLabel: "更多") {}
                    .disabled(true)
            }

            Text("禁用态（上行）").font(Typography.caption).foregroundStyle(Palette.textSecondary)
        }
        .padding(Spacing.xl)
        .frame(width: 460, height: 260, alignment: .topLeading)
        .background(Palette.surface)
    }
}

#Preview("Buttons · 深色") {
    ButtonsPreviewBoard()
        .prismTheme(PrismTheme(appearance: .dark))
}

#Preview("Buttons · 浅色") {
    ButtonsPreviewBoard()
        .prismTheme(PrismTheme(appearance: .light))
}
