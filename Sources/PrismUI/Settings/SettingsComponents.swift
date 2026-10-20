import SwiftUI

// MARK: - 分组

/// 设置页的分组容器：可选分组标题 + 一张圆角卡片 + 可选脚注。
///
/// 视觉参照 macOS「系统设置」的分组表单：标题小号、次要色、全大写（中文不受影响）；
/// 卡片用 ``Palette/surfaceElevated`` 抬升表面 + 1pt ``Palette/separator`` 描边，
/// 圆角取 ``Radius/card``。
///
/// 行与行之间的分隔线由 ``SettingsRow`` 自己画在**底部**，因此最后一行与卡片底边
/// 重合——两者同为 1pt ``Palette/separator``，视觉上不会出现「多一条线」。
///
/// ```swift
/// SettingsSection("画质", footer: "仅在转码时生效。") {
///     SettingsToggle("限制峰值码率", isOn: $settings.limitsBitrate)
/// }
/// ```
public struct SettingsSection<Content: View>: View {
    private let title: LocalizedStringKey?
    private let footer: LocalizedStringKey?
    private let content: Content

    /// 创建分组。
    ///
    /// - Parameters:
    ///   - title: 分组标题；传 `nil` 表示不显示标题。
    ///   - footer: 分组脚注（补充说明），可选。
    ///   - content: 分组内容，通常是一到多个 ``SettingsRow``。
    public init(
        _ title: LocalizedStringKey? = nil,
        footer: LocalizedStringKey? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if let title {
                Text(title)
                    .font(Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(Palette.textSecondary)
                    .textCase(.uppercase)
                    .padding(.leading, Spacing.xs)
                    .accessibilityAddTraits(.isHeader)
            }

            VStack(spacing: 0) {
                content
            }
            .background {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Palette.surfaceElevated)
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Palette.separator, lineWidth: 1)
            }

            if let footer {
                Text(footer)
                    .font(Typography.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, Spacing.xs)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 行

/// 一行设置：左侧标题 + 说明，右侧控件。
///
/// 说明文字是**必填语义**（可空但应尽量给）：设置项光有标题往往看不出「什么时候生效」，
/// 而 `docs/research/ux-benchmark.md` §S15 要求每个选项都能自解释。
///
/// 控件默认靠右对齐；``controlWidth`` 用来给 Picker / Slider 固定宽度，
/// 避免不同行的控件左右跳动。
public struct SettingsRow<Control: View>: View {
    private let title: LocalizedStringKey
    private let description: LocalizedStringKey?
    private let showsDivider: Bool
    private let controlWidth: CGFloat?
    private let control: Control

    /// 创建一行设置。
    ///
    /// - Parameters:
    ///   - title: 标题。
    ///   - description: 一句说明（何时生效、影响什么），可选。
    ///   - showsDivider: 是否在底部画分隔线；默认 `true`（分组最后一行与卡片底边重合，可保留）。
    ///   - controlWidth: 控件固定宽度；`nil` 表示由控件自身决定。
    ///   - control: 右侧控件。
    public init(
        _ title: LocalizedStringKey,
        description: LocalizedStringKey? = nil,
        showsDivider: Bool = true,
        controlWidth: CGFloat? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.description = description
        self.showsDivider = showsDivider
        self.controlWidth = controlWidth
        self.control = control()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary)

                if let description {
                    Text(description)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            control
                .frame(width: controlWidth, alignment: .trailing)
                .layoutPriority(1)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm + 2)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle()
                    .fill(Palette.separator)
                    .frame(height: 1)
                    .padding(.leading, Spacing.md)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - 开关

/// 开关行：标题 + 说明 + 右侧开关。
///
/// 用 `.toggleStyle(.switch)` 而不是默认的复选框：macOS 13 起「系统设置」统一用开关，
/// 与系统观感一致。标签隐藏后用标题做无障碍标签，VoiceOver 不会读两遍。
public struct SettingsToggle: View {
    private let title: LocalizedStringKey
    private let description: LocalizedStringKey?
    private let showsDivider: Bool
    @Binding private var isOn: Bool

    /// 创建开关行。
    ///
    /// - Parameters:
    ///   - title: 标题。
    ///   - description: 说明文字，可选。
    ///   - showsDivider: 是否画底部分隔线。
    ///   - isOn: 开关绑定。
    public init(
        _ title: LocalizedStringKey,
        description: LocalizedStringKey? = nil,
        showsDivider: Bool = true,
        isOn: Binding<Bool>
    ) {
        self.title = title
        self.description = description
        self.showsDivider = showsDivider
        self._isOn = isOn
    }

    public var body: some View {
        SettingsRow(title, description: description, showsDivider: showsDivider) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(Text(title))
        }
    }
}

// MARK: - 选择器

/// 选择器行：标题 + 说明 + 右侧下拉 / 分段控件。
///
/// `Value` 只需要 `Hashable`，因此枚举、`Int`、`String?` 都能直接绑定。
/// 选项少且文字短（≤4 个）时用 ``Style/segmented``，否则用 ``Style/menu``。
public struct SettingsPicker<Value: Hashable>: View {
    /// 选择器外观。
    public enum Style: Sendable {
        /// 下拉菜单（默认）：适合选项多或文字长。
        case menu
        /// 分段控件：适合 2–4 个短选项，一眼可见全部选择。
        case segmented
    }

    private let title: LocalizedStringKey
    private let description: LocalizedStringKey?
    private let showsDivider: Bool
    private let options: [Value]
    private let style: Style
    private let width: CGFloat
    private let label: (Value) -> LocalizedStringKey
    @Binding private var selection: Value

    /// 创建选择器行。
    ///
    /// - Parameters:
    ///   - title: 标题。
    ///   - description: 说明文字，可选。
    ///   - showsDivider: 是否画底部分隔线。
    ///   - selection: 选中值绑定。
    ///   - options: 全部可选值（顺序即展示顺序）。
    ///   - style: 下拉或分段，默认下拉。
    ///   - width: 控件宽度，默认 168pt。
    ///   - label: 把值映射成显示文案。
    public init(
        _ title: LocalizedStringKey,
        description: LocalizedStringKey? = nil,
        showsDivider: Bool = true,
        selection: Binding<Value>,
        options: [Value],
        style: Style = .menu,
        width: CGFloat = 168,
        label: @escaping (Value) -> LocalizedStringKey
    ) {
        self.title = title
        self.description = description
        self.showsDivider = showsDivider
        self._selection = selection
        self.options = options
        self.style = style
        self.width = width
        self.label = label
    }

    public var body: some View {
        SettingsRow(title, description: description, showsDivider: showsDivider, controlWidth: width) {
            switch style {
            case .menu:
                picker
                    .labelsHidden()
                    .pickerStyle(.menu)
            case .segmented:
                picker
                    .labelsHidden()
                    .pickerStyle(.segmented)
            }
        }
    }

    private var picker: some View {
        Picker("", selection: $selection) {
            ForEach(options, id: \.self) { option in
                Text(label(option))
                    .tag(option)
            }
        }
        .accessibilityLabel(Text(title))
    }
}

// MARK: - 滑块

/// 滑块行：标题 + 说明 + 右侧「滑块 + 数值」。
///
/// 数值文本用等宽数字（`.monospacedDigit()`），拖动时宽度不抖。
public struct SettingsSlider: View {
    private let title: LocalizedStringKey
    private let description: LocalizedStringKey?
    private let showsDivider: Bool
    private let range: ClosedRange<Double>
    private let step: Double
    private let sliderWidth: CGFloat
    private let valueText: (Double) -> String
    @Binding private var value: Double

    /// 创建滑块行。
    ///
    /// - Parameters:
    ///   - title: 标题。
    ///   - description: 说明文字，可选。
    ///   - showsDivider: 是否画底部分隔线。
    ///   - value: 数值绑定。
    ///   - range: 取值范围。
    ///   - step: 步长，默认 `0.05`。
    ///   - sliderWidth: 滑块宽度，默认 120pt。
    ///   - valueText: 把数值格式化成右侧标签（例如 `"125%"`）。
    public init(
        _ title: LocalizedStringKey,
        description: LocalizedStringKey? = nil,
        showsDivider: Bool = true,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double = 0.05,
        sliderWidth: CGFloat = 120,
        valueText: @escaping (Double) -> String
    ) {
        self.title = title
        self.description = description
        self.showsDivider = showsDivider
        self._value = value
        self.range = range
        self.step = step
        self.sliderWidth = sliderWidth
        self.valueText = valueText
    }

    public var body: some View {
        SettingsRow(title, description: description, showsDivider: showsDivider) {
            HStack(spacing: Spacing.sm) {
                Slider(value: $value, in: range, step: step)
                    .frame(width: sliderWidth)
                    .accessibilityLabel(Text(title))

                Text(verbatim: valueText(value))
                    .font(Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }
}

// MARK: - 提示

/// 行内提示条：信息 / 警告两种语气。
///
/// 用于「需要重启才生效」「位图字幕无法改样式」「v1.0 不做」这类**必须让用户知道**的
/// 限制说明。文案要给出原因与替代方案，而不只是「不支持」。
public struct SettingsNote: View {
    /// 提示语气。
    public enum Kind: Sendable {
        /// 中性信息。
        case information
        /// 警告：会影响用户预期或造成困惑。
        case warning
    }

    private let kind: Kind
    private let text: LocalizedStringKey

    /// 创建提示条。
    ///
    /// - Parameters:
    ///   - text: 提示文案。
    ///   - kind: 语气，默认信息。
    public init(_ text: LocalizedStringKey, kind: Kind = .information) {
        self.text = text
        self.kind = kind
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: kind == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(kind == .warning ? Color.orange : Palette.textSecondary)
                .accessibilityHidden(true)

            Text(text)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.surfaceElevated.opacity(0.65))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.separator, lineWidth: 1)
        }
    }
}

// MARK: - 语言选项

/// 音轨 / 字幕轨的可选语言。
///
/// Emby 的 `MediaStream.Language` 通常是 ISO 639-2 三字母代码（`chi` / `eng`），
/// 但也可能被媒体库刮削成两字母（`zh` / `en`），因此这里同时保留两种写法，
/// 并按代码匹配；匹配不上时把原值原样显示为「自定义」，不静默丢弃用户的设置。
struct MediaLanguageOption: Hashable, Identifiable {
    /// Emby 侧的语言代码；`nil` 表示「自动」。
    let code: String?
    /// 显示文案（存 `String` 而不是 `LocalizedStringKey`：后者不是 `Hashable`，
    /// 而 `Picker` 的 tag 需要可哈希的选项值）。
    let label: String

    /// `Identifiable` 要求；「自动」用固定字符串占位。
    var id: String { code ?? "auto" }

    /// 「自动」选项。
    static let automatic = MediaLanguageOption(code: nil, label: "自动")

    /// 全部预设选项。
    static let all: [MediaLanguageOption] = [
        .automatic,
        MediaLanguageOption(code: "chi", label: "中文"),
        MediaLanguageOption(code: "eng", label: "英语"),
        MediaLanguageOption(code: "jpn", label: "日语"),
        MediaLanguageOption(code: "kor", label: "韩语"),
        MediaLanguageOption(code: "fra", label: "法语"),
        MediaLanguageOption(code: "deu", label: "德语"),
        MediaLanguageOption(code: "spa", label: "西班牙语")
    ]

    /// 把持久化的语言代码映射回选项。
    ///
    /// - Parameter code: `AppSettings` 里存的代码；`nil` / 空串表示自动。
    /// - Returns: 匹配的预设；未知代码返回一个「自定义」选项，保证 Picker 有对应 tag。
    static func option(for code: String?) -> MediaLanguageOption {
        guard let code, !code.isEmpty else { return .automatic }
        if let match = all.first(where: { $0.code?.caseInsensitiveCompare(code) == .orderedSame }) {
            return match
        }
        return MediaLanguageOption(code: code, label: "\(code)（自定义）")
    }
}

// MARK: - 预览

private struct SettingsComponentsPreviewBoard: View {
    @State private var toggleOn = true
    @State private var scale = 1.25
    @State private var language = MediaLanguageOption.automatic
    @State private var mode = 1

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                SettingsSection("分组标题", footer: "分组脚注：补充说明这一组的生效条件。") {
                    SettingsRow("只有标题的行") {
                        Text(verbatim: "值")
                            .font(Typography.body)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    SettingsRow("带说明的行", description: "说明文字会换行，并在左侧与标题一起构成标签列。") {
                        Text(verbatim: "值")
                            .font(Typography.body)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    SettingsToggle("开关行", description: "开关即时生效并写入 UserDefaults。", isOn: $toggleOn)
                }

                SettingsSection("选择器与滑块") {
                    SettingsPicker(
                        "下拉选择",
                        description: "选项较多时用下拉。",
                        selection: $language,
                        options: MediaLanguageOption.all
                    ) { LocalizedStringKey($0.label) }

                    SettingsPicker(
                        "分段选择",
                        description: "2–4 个短选项时用分段控件。",
                        selection: $mode,
                        options: [0, 1, 2],
                        style: .segmented,
                        width: 150
                    ) { value in
                        switch value {
                        case 0: "小"
                        case 1: "中"
                        default: "大"
                        }
                    }

                    SettingsSlider(
                        "滑块行",
                        description: "拖动时右侧数值等宽显示，宽度不抖。",
                        value: $scale,
                        in: 0.5...2.0,
                        step: 0.05
                    ) { value in
                        "\(Int((value * 100).rounded()))%"
                    }
                }

                SettingsNote("信息提示：用于说明「什么时候生效」。")
                SettingsNote("警告提示：用于说明 v1.0 的已知限制与替代方案。", kind: .warning)
            }
            .padding(Spacing.xl)
        }
        .frame(width: 620, height: 720)
        .background(Palette.surface)
    }
}

#Preview("设置组件 · 深色") {
    SettingsComponentsPreviewBoard()
        .prismTheme(PrismTheme(appearance: .dark))
}

#Preview("设置组件 · 浅色") {
    SettingsComponentsPreviewBoard()
        .prismTheme(PrismTheme(appearance: .light))
}
