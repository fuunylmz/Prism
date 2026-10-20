import PrismCore
import PrismPlayback

// MARK: - 设置页 → 播放偏好

/// 把 ``PrismCore/AppSettings`` 翻译成协商层认识的 ``PrismPlayback/PlaybackPreferences``。
///
/// 为什么需要这一层：设置页与协商层分属两个模块，`PrismPlayback` 不该认识
/// `AppSettings`（那是 UI 侧的持久化偏好），而 `PrismUI` 又已经依赖两者。
/// 转换放在这里，两边都保持自己的边界。
///
/// - Important: 这个转换**必须**被真实播放路径使用。曾经 `PlaybackCoordinator`
///   直接构造 `PlaybackPreferences()`，导致设置页的「限制峰值码率」「首选音轨语言」
///   「首选字幕语言」对播放零影响——用户改了设置，行为完全不变。
extension PlaybackPreferences {
    /// 从应用设置构造播放偏好。
    ///
    /// - Parameter settings: 应用设置。
    @MainActor
    public init(appSettings settings: AppSettings) {
        let presetBitrate = settings.preferredQuality.suggestedBitrateMbps ?? 0
        let manualBitrate = settings.maxBitrateMbps

        // 两个来源取更严格的那个：预设给的是「1080p ≈ 20Mbps」这类建议值，
        // 手填的是用户明确的上限，任何一个生效都应该被尊重。
        let limits = [presetBitrate, manualBitrate].filter { $0 > 0 }

        self.init(
            maxBitrateMbps: limits.min() ?? 0,
            // v1.0 没有「强制转码」开关：画质限制靠码率上限表达，
            // 直连优先始终开启（官方推荐的选源顺序）。
            preferDirectPlay: true,
            forceTranscode: false,
            preferredAudioLanguage: Self.normalizedLanguage(settings.preferredAudioLanguage),
            preferredSubtitleLanguage: Self.normalizedLanguage(settings.preferredSubtitleLanguage),
            burnInImageSubtitles: true
        )
    }

    /// 归一化语言代码：空串视为「不干预」，统一成小写。
    ///
    /// Emby 的 `Language` 字段用 ISO 639-2（`chi` / `eng`），设置页存的也可能是
    /// `zh` / `en`。这里只做「去空白 + 小写」，具体的模糊匹配交给协商层
    /// （它已经按前缀比对，`zh` 能命中 `zho` / `chi`）。
    ///
    /// - Parameter language: 原始语言代码。
    /// - Returns: 归一化后的代码；无有效值时 `nil`。
    private static func normalizedLanguage(_ language: String?) -> String? {
        guard let trimmed = language?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed.lowercased()
    }
}
