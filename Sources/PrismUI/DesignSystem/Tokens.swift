import AppKit
import SwiftUI

// MARK: - 间距

/// 间距刻度（8pt 基准，允许 4pt 半格）。
///
/// 命名与数值来自 `docs/ARCHITECTURE.md` §5.1 的**冻结契约**，任何调用方
/// （尤其是 `PrismUI/AppShell/`）都按这些名字取值，**不得改名或改值**。
///
/// 与 `docs/research/ux-benchmark.md` §5.4 的差异：UX 文档的刻度整体比这里多一档
/// （它把 4 叫 `xxs`、8 叫 `xs`……），本文件以架构契约为准。
public enum Spacing {
    /// 4pt：图标与文字之间、角标内边距。
    public static let xs: CGFloat = 4
    /// 8pt：控件内部、标题与副标题之间。
    public static let sm: CGFloat = 8
    /// 12pt：表单行距、紧凑分组。
    public static let md: CGFloat = 12
    /// 16pt：卡片间距、内容区常规留白。
    public static let lg: CGFloat = 16
    /// 24pt：区块之间、页面左右边距。
    public static let xl: CGFloat = 24
    /// 32pt：大区块之间、空态留白。
    public static let xxl: CGFloat = 32
}

// MARK: - 圆角

/// 圆角刻度。
///
/// 命名与数值来自 `docs/ARCHITECTURE.md` §5.1 的冻结契约。
///
/// HIG 的「同心圆角」要求：内层控件的圆角 = 外层容器圆角 − 内边距；
/// 例如 `Radius.panel` 的容器内放 `Radius.card` 的卡片时，两者之差应等于卡片内边距。
public enum Radius {
    /// 10pt：卡片、按钮、输入框。
    public static let card: CGFloat = 10
    /// 8pt：海报、缩略图。
    public static let poster: CGFloat = 8
    /// 14pt：浮层、popover、面板。
    public static let panel: CGFloat = 14
}

// MARK: - 字体

/// 字体层级。
///
/// 全部走 **Dynamic Type 语义字体**（`.largeTitle` / `.title2` / `.headline` …），
/// 而不是写死 `size:`：这样系统「辅助功能 › 显示 › 文字大小」与放大镜才能生效。
/// 具体字号参考 `docs/research/ux-benchmark.md` §5.3 的字体表，但以语义字号为准。
public enum Typography {
    /// 大标题（34pt Bold 量级）：欢迎页、整页空态主标题。
    public static let titleLarge: Font = .system(.largeTitle, design: .default, weight: .bold)
    /// 页标题（22pt Semibold 量级）：库名、详情页标题。
    public static let title: Font = .system(.title2, design: .default, weight: .semibold)
    /// 卡片标题 / 按钮文字（17pt Semibold 量级）。
    public static let headline: Font = .headline
    /// 正文（17pt Regular 量级）。
    public static let body: Font = .body
    /// 说明文字 / 角标（11–13pt 量级）。
    public static let caption: Font = .caption
    /// 时间码：等宽设计 + 等宽数字，避免播放器计时跳动。
    public static let monoTime: Font = .system(.footnote, design: .monospaced, weight: .medium).monospacedDigit()
}

// MARK: - 颜色

/// 语义色板（深色 / 浅色双主题）。
///
/// **设计原则：优先使用 macOS 系统语义色，而不是写死十六进制。**
/// 系统语义色会随外观、用户选择的强调色、以及「辅助功能 › 显示 › 增强对比度」
/// 自动切换；写死色值会让浅色模式、增强对比度与高对比度用户直接失效。
///
/// 视觉方向参考 `docs/research/ux-benchmark.md` §5.1（影院暗色）与 §5.2（系统原生浅色），
/// 但落地时统一收敛到 HIG 语义色：v1.0 的「影院感」由布局、留白与海报本身承担，
/// 而不是靠自定义灰阶。
///
/// > 后续如需 Prism 品牌紫（`#7B5CFF`），应由 Asset Catalog 的 AccentColor 提供
/// > （Any / Dark 两套），届时只需把 ``accent`` 换成 `Color("AccentColor")`，
/// > 调用点无需改动。当前 PrismUI target 没有资源目录，故使用系统强调色。
public enum Palette {
    /// 强调色：跟随系统「外观 › 强调色」设置，用于主按钮、选中态、进度条、焦点环。
    public static let accent: Color = Color(nsColor: .controlAccentColor)

    /// 窗口底色（L0）。深色下接近 `#1E1E1E`，浅色下接近 `#ECECEC`。
    public static let surface: Color = Color(nsColor: .windowBackgroundColor)

    /// 抬升表面（L2）：卡片、浮层、输入框背景。
    public static let surfaceElevated: Color = Color(nsColor: .controlBackgroundColor)

    /// 分割线 / 描边。深色浅色都是系统调好的低对比度线条。
    public static let separator: Color = Color(nsColor: .separatorColor)

    /// 主文字色。**用 `.primary` 而不是自定义白/黑**，才能跟随外观与增强对比度。
    public static let textPrimary: Color = .primary

    /// 次要文字色（年份、时长、说明）。
    public static let textSecondary: Color = .secondary

    /// 遮罩：海报 hover 压暗、播放器浮层背景。遮罩在两种外观下都应是暗色，
    /// 因此用固定黑色 + 透明度，而不是语义背景色。
    public static let scrim: Color = .black.opacity(0.55)
}

// MARK: - 动效

/// 动效时长（秒）。
///
/// 数值来自 `docs/ARCHITECTURE.md` §5.1 的冻结契约。调用处自行选择曲线，例如
/// `withAnimation(.easeOut(duration: Motion.quick)) { ... }`。
///
/// **尊重「减弱动态效果」**：需要动画的组件应读取
/// `@Environment(\.accessibilityReduceMotion)`，在开启时直接使用 `nil` 动画
/// （见 `SkeletonView` / `PosterCard` 的实现）。
public enum Motion {
    /// 0.15s：hover 缩放、选中态、按压反馈。
    public static let quick: Double = 0.15
    /// 0.25s：内容切换、错误态/空态出现。
    public static let standard: Double = 0.25
    /// 0.4s：整块布局变化、面板进出。
    public static let slow: Double = 0.4
}

// MARK: - 主题

/// Prism 主题配置。
///
/// 只描述「外观策略」，不承载业务逻辑；由 AppShell 在最外层通过
/// ``SwiftUI/View/prismTheme(_:)`` 挂载一次即可。
///
/// ```swift
/// RootView()
///     .prismTheme(PrismTheme(appearance: .dark))
/// ```
///
/// 默认 ``Appearance/system``：完全跟随系统外观，符合 HIG；若产品决定 v1.0 默认
/// 「影院暗色」，由 AppShell 传 `.dark`，设计系统不需要改。
public struct PrismTheme: Sendable, Equatable {
    /// 外观策略。
    public enum Appearance: String, Sendable, Equatable, CaseIterable, Identifiable {
        /// 跟随系统（默认）。
        case system
        /// 强制浅色。
        case light
        /// 强制深色。
        case dark

        /// `Identifiable` 要求的稳定 id。
        public var id: String { rawValue }

        /// 传给 `preferredColorScheme(_:)` 的值；`system` 对应 `nil`。
        public var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    /// 外观策略。
    public var appearance: Appearance

    /// 创建主题。
    ///
    /// - Parameter appearance: 外观策略，默认跟随系统。
    public init(appearance: Appearance = .system) {
        self.appearance = appearance
    }

    /// 默认主题（跟随系统）。
    public static let `default` = PrismTheme()
}

// MARK: - 主题环境

private struct PrismThemeKey: EnvironmentKey {
    static let defaultValue = PrismTheme()
}

public extension EnvironmentValues {
    /// 当前挂载的 Prism 主题。组件通过它读取外观策略（例如决定遮罩浓度）。
    var prismTheme: PrismTheme {
        get { self[PrismThemeKey.self] }
        set { self[PrismThemeKey.self] = newValue }
    }
}

private struct PrismThemeModifier: ViewModifier {
    let theme: PrismTheme

    func body(content: Content) -> some View {
        content
            .environment(\.prismTheme, theme)
            .preferredColorScheme(theme.appearance.colorScheme)
            .tint(Palette.accent)
    }
}

public extension View {
    /// 挂载 Prism 主题：写入 `prismTheme` 环境、应用 `preferredColorScheme`、设置 tint。
    ///
    /// 这是 AppShell 唯一需要调用的主题入口；它不会改变布局，也不会给视图加背景。
    ///
    /// - Parameter theme: 主题配置，默认 ``PrismTheme/default``（跟随系统）。
    /// - Returns: 已挂载主题的视图。
    func prismTheme(_ theme: PrismTheme = .default) -> some View {
        modifier(PrismThemeModifier(theme: theme))
    }
}

// MARK: - 预览

/// Token 总览板：色板 + 字体 + 间距 + 圆角，用来肉眼核对两套外观。
private struct TokensPreviewBoard: View {
    private let spacingSamples: [(String, CGFloat)] = [
        ("xs", Spacing.xs), ("sm", Spacing.sm), ("md", Spacing.md),
        ("lg", Spacing.lg), ("xl", Spacing.xl), ("xxl", Spacing.xxl)
    ]

    private let radiusSamples: [(String, CGFloat)] = [
        ("poster", Radius.poster), ("card", Radius.card), ("panel", Radius.panel)
    ]

    private let paletteSamples: [(String, Color)] = [
        ("accent", Palette.accent),
        ("surface", Palette.surface),
        ("surfaceElevated", Palette.surfaceElevated),
        ("separator", Palette.separator),
        ("textPrimary", Palette.textPrimary),
        ("textSecondary", Palette.textSecondary),
        ("scrim", Palette.scrim)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                Text("Typography").font(Typography.titleLarge)
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("titleLarge · 34 Bold").font(Typography.titleLarge)
                    Text("title · 22 Semibold").font(Typography.title)
                    Text("headline · 17 Semibold").font(Typography.headline)
                    Text("body · 17 Regular").font(Typography.body)
                    Text("caption · 11–13").font(Typography.caption)
                    Text("monoTime · 00:12:34").font(Typography.monoTime)
                }

                Text("Palette").font(Typography.title)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: Spacing.md)], spacing: Spacing.md) {
                    ForEach(paletteSamples, id: \.0) { name, color in
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            RoundedRectangle(cornerRadius: Radius.poster, style: .continuous)
                                .fill(color)
                                .frame(height: 44)
                                .overlay {
                                    RoundedRectangle(cornerRadius: Radius.poster, style: .continuous)
                                        .strokeBorder(Palette.separator, lineWidth: 1)
                                }
                            Text(name).font(Typography.caption).foregroundStyle(Palette.textSecondary)
                        }
                    }
                }

                Text("Spacing").font(Typography.title)
                ForEach(spacingSamples, id: \.0) { name, value in
                    HStack(spacing: Spacing.md) {
                        Text(name).font(Typography.caption).frame(width: 40, alignment: .leading)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Palette.accent)
                            .frame(width: value, height: 12)
                        Text("\(Int(value))pt").font(Typography.caption).foregroundStyle(Palette.textSecondary)
                    }
                }

                Text("Radius").font(Typography.title)
                HStack(spacing: Spacing.md) {
                    ForEach(radiusSamples, id: \.0) { name, value in
                        VStack(spacing: Spacing.xs) {
                            RoundedRectangle(cornerRadius: value, style: .continuous)
                                .fill(Palette.surfaceElevated)
                                .frame(width: 80, height: 56)
                            Text("\(name) \(Int(value))").font(Typography.caption).foregroundStyle(Palette.textSecondary)
                        }
                    }
                }
            }
            .padding(Spacing.xxl)
        }
        .background(Palette.surface)
        .frame(width: 620, height: 720)
    }
}

#Preview("Tokens · 深色") {
    TokensPreviewBoard()
        .prismTheme(PrismTheme(appearance: .dark))
}

#Preview("Tokens · 浅色") {
    TokensPreviewBoard()
        .prismTheme(PrismTheme(appearance: .light))
}
