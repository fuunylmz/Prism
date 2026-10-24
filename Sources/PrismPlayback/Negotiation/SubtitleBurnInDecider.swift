import Foundation
import PrismCore

/// 判断某条字幕轨**是否必须烧录进画面**（进而决定「是不是必须转码」）。
///
/// ## 为什么图形字幕必须烧录
///
/// 播放内核（AetherEngine）对图形字幕提供解码后的 `CGImage` cue，由 Prism 叠加显示。
/// 该判定器只决定是否额外要求 Emby 把图形字幕烧进转码画面：
///
/// 1. **烧录**（服务端 `Encode`）：必然触发视频转码，但画面正确；
/// 2. **客户端叠加**：不要求字幕烧录，保留直连/直封，并显示引擎解码出的位图 cue。
///
/// 文本字幕（SRT / ASS / VTT）相反：服务端以外挂方式给文本，客户端自己渲染，
/// 完全不需要转码（代价是复杂 ASS 特效会丢失，见 §3.5 坑 3）。
///
/// ## 与服务端能力描述的对应关系
///
/// ``SubtitleBurnInDecider`` 是**本地真相**，`.prismMacOS()` 的 `SubtitleProfiles`
/// 是**发给服务端的声明**，两者必须一致：
/// `pgssub` / `dvdsub` 声明为 `Encode`，文本字幕声明为 `External`
/// （`docs/research/emby-api.md` §6.2.4）。
///
/// 判定依据（已核实）：`MediaStream.IsTextSubtitleStream` 由服务端给出，
/// 见 <https://dev.emby.media/reference/pluginapi/MediaBrowser.Model.Entities.MediaStream.html>。
public struct SubtitleBurnInDecider: Sendable, Equatable {
    /// 图形字幕的编解码器名（已归一化：小写、去分隔符）。
    ///
    /// 覆盖 Emby 常见的几种写法：`pgssub` / `pgs` / `hdmv_pgs_subtitle`（蓝光 PGS）、
    /// `dvdsub` / `dvd_subtitle` / `vobsub`（DVD）、`dvbsub` / `dvb_subtitle`（DVB）、
    /// `xsub`（DivX）。取值参照 Emby `SubtitleProfile.Format` 与 FFmpeg 的 codec 名。
    static let imageCodecs: Set<String> = [
        "pgssub", "pgs", "hdmvpgssubtitle", "hdmvpgs",
        "dvdsub", "dvdsubtitle", "vobsub", "dvbsub", "dvbsubtitle",
        "xsub"
    ]

    /// 文本字幕的编解码器名（已归一化）。
    ///
    /// 只在服务端没给 `IsTextSubtitleStream` 时用于兜底判断 —— 否则一条 SRT 会被
    /// 误判成图形字幕，导致「本来能直连的片子被转码」。
    static let textCodecs: Set<String> = [
        "subrip", "srt", "ass", "ssa", "vtt", "webvtt", "movtext", "ttml",
        "smi", "sami", "microdvd", "subviewer", "text", "eia608", "cea608"
    ]

    /// 图形字幕是否烧录（对应 ``PlaybackPreferences/burnInImageSubtitles``）。
    ///
    /// 为 `false` 时，图形字幕不触发服务端烧录，由客户端叠加位图 cue。
    public let burnInImageSubtitles: Bool

    /// 编解码器无法识别、且服务端也没给 `IsTextSubtitleStream` 时，是否按图形字幕处理。
    ///
    /// 默认 `true`（保守）：宁可多转码一次，也不要出现「选了字幕却什么都不显示」。
    public let treatUnknownAsImage: Bool

    /// 完整初始化。
    ///
    /// - Parameters:
    ///   - burnInImageSubtitles: 图形字幕是否烧录。
    ///   - treatUnknownAsImage: 未知编解码器是否按图形字幕处理。
    public init(burnInImageSubtitles: Bool = true, treatUnknownAsImage: Bool = true) {
        self.burnInImageSubtitles = burnInImageSubtitles
        self.treatUnknownAsImage = treatUnknownAsImage
    }

    /// 以协商偏好创建。
    ///
    /// - Parameter preferences: 播放偏好（只读取 `burnInImageSubtitles`）。
    public init(preferences: PlaybackPreferences) {
        self.init(burnInImageSubtitles: preferences.burnInImageSubtitles)
    }

    /// 这条轨是否需要服务端烧录。
    ///
    /// - Parameter stream: 任意媒体流；非字幕轨一律返回 `false`。
    /// - Returns: 需要烧录时为 `true`（意味着该片源必须转码）。
    public func requiresBurnIn(_ stream: MediaStream) -> Bool {
        guard stream.type == .subtitle else { return false }
        guard isImageSubtitle(stream) else { return false }
        return burnInImageSubtitles
    }

    /// 这条字幕轨是否为图形字幕（与是否烧录无关）。
    ///
    /// - Parameter stream: 任意媒体流；非字幕轨一律返回 `false`。
    /// - Returns: 图形字幕（PGS / DVDSUB / VOBSUB…）时为 `true`。
    public func isImageSubtitle(_ stream: MediaStream) -> Bool {
        guard stream.type == .subtitle else { return false }

        let codec = Self.normalize(stream.codec)

        // 1. 明确的图形编码优先：即使服务端误标 IsTextSubtitleStream=true 也以编码为准。
        if Self.imageCodecs.contains(codec) { return true }

        // 2. 服务端标记（权威字段）。
        if stream.isTextSubtitleStream { return false }

        // 3. 明确的文本编码：服务端漏给 IsTextSubtitleStream 时的兜底。
        if Self.textCodecs.contains(codec) { return false }

        // 4. 编码缺失或未知。
        return treatUnknownAsImage
    }

    /// 归一化编解码器名：小写并去掉 `_` / `-` / 空格，使 `hdmv_pgs_subtitle` 与
    /// `hdmvpgssubtitle` 等价。
    ///
    /// - Parameter codec: 原始编解码器名（可空）。
    /// - Returns: 归一化结果；空输入得到空串。
    static func normalize(_ codec: String?) -> String {
        guard let codec else { return "" }
        return codec.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
