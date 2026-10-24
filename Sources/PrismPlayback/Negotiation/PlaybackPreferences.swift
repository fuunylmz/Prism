import Foundation
import PrismCore

/// 播放协商的用户偏好。
///
/// 这些值只影响**协商阶段**（选哪个源、用哪种方式、要不要烧字幕），
/// 不影响引擎行为。与 `PrismCore.AppSettings` 是两回事：`AppSettings` 是持久化的 UI 设置，
/// 这里是由调用方在发起播放时快照出来的纯值对象（便于测试与跨 actor 传递）。
///
/// - Note: 结构体全部字段都有默认值，`PlaybackPreferences()` 即「不限制码率、优先直连、
///   图形字幕烧录」，这是局域网直连场景的合理默认。
public struct PlaybackPreferences: Sendable, Equatable {
    /// 码率上限（Mbps）。
    ///
    /// `0` 表示**不限制**（默认）。超过上限的源会被强制转码，原因记为
    /// ``NegotiationReason/bitrateExceeded(_:limit:)``。
    ///
    /// 单位是 Mbps 而服务器用 bps，转换只在 ``PlaybackNegotiator`` 内部做一次。
    public var maxBitrateMbps: Int

    /// 是否优先直连（默认 `true`）。
    ///
    /// 为 `true` 时，多版本条目里优先挑 `SupportsDirectPlay == true` 的源（官方推荐算法 Step 1，
    /// <https://dev.emby.media/doc/restapi/Playback-Guidelines.html>）。
    /// 为 `false` 时直接取第一个源，交由后续能力判定处理。
    public var preferDirectPlay: Bool

    /// 强制转码（默认 `false`）。
    ///
    /// 调试 / 兼容用：置 `true` 后无论源是否支持直连，一律走转码，
    /// 原因记为 ``NegotiationReason/userForcedTranscode``。
    /// 典型用途：排查「某些片源直连会花屏」这类解码器问题。
    public var forceTranscode: Bool

    /// 首选音频语言（ISO 639-1/2，如 `"chi"`、`"eng"`）。
    ///
    /// `nil` 表示不干预，沿用服务器算出的默认音轨。
    /// 命中规则见 ``PlaybackNegotiator``：只在调用方没显式指定音轨时才生效。
    public var preferredAudioLanguage: String?

    /// 首选字幕语言（ISO 639-1/2）。
    ///
    /// `nil` 时 `interfaceLanguage` 作为「自动」语言参考。
    public var preferredSubtitleLanguage: String?

    /// 界面语言对应的字幕语言（ISO 639-1/2），用于 `.foreign` 自动显示策略。
    public var interfaceLanguage: String?

    /// 自动字幕策略。
    public var subtitleMode: SubtitleMode

    /// 图形字幕（PGS / DVDSUB / VOBSUB）是否烧录（默认 `true`）。
    ///
    /// - `true`：图形字幕必须烧进画面 → 该片源**必然转码**。
    /// - `false`：不要求服务端烧录；支持时由客户端把引擎解码出的位图 cue 叠加到画面。
    ///
    /// 依据：`.prismMacOS()` 的 `SubtitleProfiles` 把 `pgssub` / `dvdsub` 声明为 `Encode`，
    /// 见 `docs/research/emby-api.md` §6.2.4 的取舍说明。
    public var burnInImageSubtitles: Bool

    /// 完整初始化。
    ///
    /// - Parameters:
    ///   - maxBitrateMbps: 码率上限（Mbps），`0` = 不限制。
    ///   - preferDirectPlay: 是否优先直连。
    ///   - forceTranscode: 是否强制转码。
    ///   - preferredAudioLanguage: 首选音频语言。
    ///   - preferredSubtitleLanguage: 首选字幕语言。
    ///   - interfaceLanguage: `.foreign` 模式的界面语言。
    ///   - subtitleMode: 自动字幕策略。
    ///   - burnInImageSubtitles: 图形字幕是否烧录。
    public init(
        maxBitrateMbps: Int = 0,
        preferDirectPlay: Bool = true,
        forceTranscode: Bool = false,
        preferredAudioLanguage: String? = nil,
        preferredSubtitleLanguage: String? = nil,
        interfaceLanguage: String? = nil,
        subtitleMode: SubtitleMode = .foreign,
        burnInImageSubtitles: Bool = true
    ) {
        self.maxBitrateMbps = maxBitrateMbps
        self.preferDirectPlay = preferDirectPlay
        self.forceTranscode = forceTranscode
        self.preferredAudioLanguage = preferredAudioLanguage
        self.preferredSubtitleLanguage = preferredSubtitleLanguage
        self.interfaceLanguage = interfaceLanguage
        self.subtitleMode = subtitleMode
        self.burnInImageSubtitles = burnInImageSubtitles
    }

    /// 默认偏好：不限制码率、优先直连、图形字幕烧录。
    public static let `default` = PlaybackPreferences()

    /// 码率上限换算成 bps；`nil` 表示不限制。
    ///
    /// 负数按「不限制」处理，避免调用方误传 `-1` 时把一切都判成超限。
    public var bitrateLimitBps: Int? {
        maxBitrateMbps > 0 ? maxBitrateMbps * 1_000_000 : nil
    }
}
