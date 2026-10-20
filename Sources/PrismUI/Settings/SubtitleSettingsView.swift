import PrismCore
import SwiftUI

// MARK: - 字幕设置

/// 字幕面板：语言、显示模式、字号、背景，并带一块**实时预览**。
///
/// 预览区用一块模拟画面（深色渐变）承载示例字幕，字号与背景直接读当前设置，
/// 因此拖动滑块或切换开关时预览立即变化，不需要「应用」。
///
/// ## 已知边界（必须告诉用户）
///
/// 字号与背景只对**文本字幕**（SRT / ASS / WebVTT）生效。位图字幕（PGS / VobSub /
/// DVD SUB）是烧在画面里的图像，播放器无法改字号或底色——这类字幕按原始分辨率渲染。
struct SubtitleSettingsView: View {
    /// 设置存储。
    @Bindable var settings: AppSettings

    /// 示例字幕的第一行。
    private let sampleLineOne: LocalizedStringKey = "这就是我们最后的机会了。"
    /// 示例字幕的第二行。
    private let sampleLineTwo: LocalizedStringKey = "天亮之前，我们得赶到那座桥。"

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            SettingsSection("字幕轨道") {
                SettingsPicker(
                    "首选字幕语言",
                    description: "自动加载字幕时优先匹配的语言。「自动」沿用服务器标记的默认字幕。",
                    selection: subtitleLanguageBinding,
                    options: MediaLanguageOption.all
                ) { LocalizedStringKey($0.label) }

                SettingsPicker(
                    "字幕显示模式",
                    description: "决定什么时候**自动**打开字幕；手动开关始终可用。",
                    showsDivider: false,
                    selection: $settings.subtitleMode,
                    options: SubtitleMode.allCases
                ) { mode in
                    mode.settingsLabel
                }
            }

            SettingsNote(settings.subtitleMode.settingsExplanation)

            SettingsSection("字幕样式") {
                SettingsSlider(
                    "字幕大小",
                    description: "相对基准字号的缩放比例，50%–200%。只影响文本字幕。",
                    value: $settings.subtitleScale,
                    in: AppSettings.subtitleScaleRange,
                    step: 0.05
                ) { value in
                    "\(Int((value * 100).rounded()))%"
                }

                SettingsToggle(
                    "字幕背景",
                    description: "在字幕文字后面加一层半透明底色，画面较亮时更容易读。",
                    showsDivider: false,
                    isOn: $settings.subtitleBackground
                )
            }

            previewSection

            SettingsNote("字号与背景只对 SRT / ASS / WebVTT 等文本字幕生效；PGS、VobSub 等位图字幕按原始画面渲染，无法调整。", kind: .warning)
        }
    }

    // MARK: 预览

    /// 实时预览：模拟画面 + 按当前设置渲染的示例字幕。
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("预览")
                    .font(Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(Palette.textSecondary)
                    .textCase(.uppercase)
                    .accessibilityAddTraits(.isHeader)

                Spacer(minLength: Spacing.sm)

                Text(verbatim: previewCaption)
                    .font(Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }

            ZStack(alignment: .bottom) {
                // 模拟画面：深色渐变 + 一个高光，接近真实播放时的字幕背景对比度。
                LinearGradient(
                    colors: [Color(red: 0.10, green: 0.12, blue: 0.16), Color(red: 0.03, green: 0.04, blue: 0.06)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(.white.opacity(0.10))
                        .frame(width: 140, height: 140)
                        .blur(radius: 36)
                        .offset(x: 30, y: -40)
                }

                VStack(spacing: 4) {
                    subtitleLine(sampleLineOne)
                    subtitleLine(sampleLineTwo)
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.bottom, Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .center)
                .animation(nil, value: settings.subtitleScale)
            }
            .frame(height: 132)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Palette.separator, lineWidth: 1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("字幕预览")
            .accessibilityValue(previewCaption)

            Text("预览按 100% 基准字号换算，实际大小取决于播放窗口与片源分辨率。")
                .font(Typography.caption)
                .foregroundStyle(.tertiary)
        }
    }

    /// 单行示例字幕。
    ///
    /// - Parameter text: 字幕内容。
    /// - Returns: 按当前缩放与背景设置渲染的一行。
    private func subtitleLine(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: Self.baseFontSize * settings.subtitleScale, weight: .medium))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.85), radius: 2, x: 0, y: 1)
            .padding(.horizontal, settings.subtitleBackground ? 6 : 0)
            .padding(.vertical, settings.subtitleBackground ? 2 : 0)
            .background {
                if settings.subtitleBackground {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.black.opacity(0.62))
                }
            }
            .multilineTextAlignment(.center)
    }

    /// 预览右上角的参数摘要。
    private var previewCaption: String {
        let percent = Int((settings.subtitleScale * 100).rounded())
        return settings.subtitleBackground ? "\(percent)% · 背景开" : "\(percent)% · 背景关"
    }

    /// 预览基准字号（pt）。
    private static let baseFontSize: CGFloat = 15

    // MARK: 语言

    /// 字幕语言绑定：`String?` ↔ ``MediaLanguageOption``。
    private var subtitleLanguageBinding: Binding<MediaLanguageOption> {
        Binding(
            get: { MediaLanguageOption.option(for: settings.preferredSubtitleLanguage) },
            set: { settings.preferredSubtitleLanguage = $0.code }
        )
    }
}

// MARK: - 枚举文案

extension SubtitleMode {
    /// 设置页显示名。
    var settingsLabel: LocalizedStringKey {
        switch self {
        case .always: "总是显示"
        case .forced: "仅强制字幕"
        case .foreign: "外语对白时"
        case .never: "从不自动显示"
        }
    }

    /// 当前模式的详细说明（显示在分组下方，随选择变化）。
    var settingsExplanation: LocalizedStringKey {
        switch self {
        case .always:
            "只要片源带字幕就自动加载并显示，包括完整对白字幕。"
        case .forced:
            "只加载标记为「强制」的字幕轨（通常只有外语对白的翻译），适合已熟悉原声的观众。"
        case .foreign:
            "音轨语言与界面语言不同时才自动显示字幕；中文音轨配中文字幕时不会打扰你。"
        case .never:
            "从不自动显示字幕，需要时在播放器里手动打开。"
        }
    }
}

// MARK: - 预览

#Preview("字幕设置 · 深色") {
    ScrollView {
        SubtitleSettingsView(settings: AppSettings(defaults: .standard, keyPrefix: "preview.subtitles."))
            .padding(Spacing.xl)
    }
    .frame(width: 620, height: 780)
    .background(Palette.surface)
    .prismTheme(PrismTheme(appearance: .dark))
}

#Preview("字幕设置 · 浅色") {
    ScrollView {
        SubtitleSettingsView(settings: AppSettings(defaults: .standard, keyPrefix: "preview.subtitles."))
            .padding(Spacing.xl)
    }
    .frame(width: 620, height: 780)
    .background(Palette.surface)
    .prismTheme(PrismTheme(appearance: .light))
}
