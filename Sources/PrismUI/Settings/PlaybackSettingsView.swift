import PrismCore
import SwiftUI

// MARK: - 播放设置

/// 播放面板：画质偏好、码率上限、快进步长、自动连播。
///
/// 所有值直接绑定 ``PrismCore/AppSettings``，改动即时写入 `UserDefaults`，
/// 没有「保存」按钮。每个选项都带一句说明，交代**它什么时候生效**。
///
/// ```swift
/// PlaybackSettingsView(settings: .shared)
/// ```
struct PlaybackSettingsView: View {
    /// 设置存储。
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            SettingsSection("画质") {
                SettingsPicker(
                    "默认播放质量",
                    description: "起播时优先请求的清晰度。「自动」由服务器按网络状况决定；「原画」不转码，最清晰但最吃带宽。",
                    selection: $settings.preferredQuality,
                    options: QualityPreset.allCases,
                    width: 172
                ) { preset in
                    preset.settingsLabel
                }

                SettingsToggle(
                    "限制峰值码率",
                    description: "开启后可指定码率上限；关闭时按片源原始码率播放。",
                    isOn: bitrateLimitBinding
                )

                SettingsRow(
                    "码率上限",
                    description: "超过该码率的片源会请求服务器转码。数值越高越清晰、越吃带宽；仅在开启「限制峰值码率」时生效。"
                ) {
                    HStack(spacing: Spacing.sm) {
                        Slider(value: bitrateBinding, in: 1...100, step: 1)
                            .frame(width: 120)
                            .disabled(!isBitrateLimited)
                            .accessibilityLabel("码率上限")
                            .accessibilityValue(bitrateValueText)

                        Text(verbatim: bitrateValueText)
                            .font(Typography.caption)
                            .monospacedDigit()
                            .foregroundStyle(Palette.textSecondary.opacity(isBitrateLimited ? 1 : 0.55))
                            .frame(width: 72, alignment: .trailing)
                    }
                    .opacity(isBitrateLimited ? 1 : 0.5)
                }
            }

            SettingsSection("播放行为") {
                SettingsPicker(
                    "快进 / 快退步长",
                    description: "按 ← → 或点击控制条两侧按钮时跳转的秒数。",
                    selection: $settings.seekStepSeconds,
                    options: AppSettings.seekStepOptions,
                    style: .segmented,
                    width: 168
                ) { seconds in
                    "\(seconds) 秒"
                }

                SettingsToggle(
                    "自动播放下一集",
                    description: "剧集播完后自动接上下一集。关闭后停留在片尾画面，等你自己选择。",
                    isOn: $settings.autoPlayNextEpisode
                )

                SettingsPicker(
                    "首选音轨语言",
                    description: "自动选择音轨时优先匹配的语言；「自动」沿用服务器标记的默认音轨。",
                    showsDivider: false,
                    selection: audioLanguageBinding,
                    options: MediaLanguageOption.all
                ) { LocalizedStringKey($0.label) }
            }

            SettingsNote("画质与码率只影响**转码请求**：服务器支持直连时，原画始终优于转码结果。局域网建议「自动」或「原画」。")
        }
    }

    // MARK: 码率

    /// 是否限制码率（`maxBitrateMbps == 0` 表示不限制）。
    private var isBitrateLimited: Bool {
        settings.maxBitrateMbps > 0
    }

    /// 滑块数值文本。
    private var bitrateValueText: String {
        isBitrateLimited ? "\(settings.maxBitrateMbps) Mbps" : "不限制"
    }

    /// 「限制峰值码率」开关：打开时给一个合理默认值（20 Mbps），关闭时归零。
    private var bitrateLimitBinding: Binding<Bool> {
        Binding(
            get: { isBitrateLimited },
            set: { isOn in
                if isOn {
                    if settings.maxBitrateMbps <= 0 {
                        settings.maxBitrateMbps = QualityPreset.p1080.suggestedBitrateMbps ?? 20
                    }
                } else {
                    settings.maxBitrateMbps = 0
                }
            }
        )
    }

    /// 码率滑块绑定：`0`（不限制）在滑块上显示为 1，避免滑块跳到最左端。
    private var bitrateBinding: Binding<Double> {
        Binding(
            get: { Double(max(settings.maxBitrateMbps, 1)) },
            set: { settings.maxBitrateMbps = Int($0.rounded()) }
        )
    }

    // MARK: 语言

    /// 音轨语言绑定：`String?` ↔ ``MediaLanguageOption``。
    private var audioLanguageBinding: Binding<MediaLanguageOption> {
        Binding(
            get: { MediaLanguageOption.option(for: settings.preferredAudioLanguage) },
            set: { settings.preferredAudioLanguage = $0.code }
        )
    }
}

// MARK: - 枚举文案

extension QualityPreset {
    /// 设置页显示名。
    var settingsLabel: LocalizedStringKey {
        switch self {
        case .auto: "自动"
        case .original: "原画（不转码）"
        case .p1080: "1080p"
        case .p720: "720p"
        }
    }
}

// MARK: - 预览

#Preview("播放设置 · 深色") {
    ScrollView {
        PlaybackSettingsView(settings: AppSettings(defaults: .standard, keyPrefix: "preview.playback."))
            .padding(Spacing.xl)
    }
    .frame(width: 620, height: 560)
    .background(Palette.surface)
    .prismTheme(PrismTheme(appearance: .dark))
}

#Preview("播放设置 · 浅色") {
    ScrollView {
        PlaybackSettingsView(settings: AppSettings(defaults: .standard, keyPrefix: "preview.playback."))
            .padding(Spacing.xl)
    }
    .frame(width: 620, height: 560)
    .background(Palette.surface)
    .prismTheme(PrismTheme(appearance: .light))
}
