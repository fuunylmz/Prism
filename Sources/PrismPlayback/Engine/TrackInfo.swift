import Foundation
import PrismCore

/// 一条可选轨道（音频或字幕），引擎无关的中间表示。
///
/// 两个来源：
/// 1. **引擎实际解出来的轨**——``PlaybackEvent/tracksChanged(audio:subtitle:)`` 里发出来的，
///    `id` 是引擎/容器的 stream index，`selectAudioTrack(_:)` / `selectSubtitleTrack(_:)` 直接吃这个 id；
/// 2. **Emby 声明的轨**——用 ``init?(stream:)`` 从 ``MediaStream`` 映射，供协商层与菜单预渲染。
///
/// - Note: 视频轨不在这里：播放器是单视频轨场景，引擎也不暴露视频轨列表。
public struct TrackInfo: Sendable, Equatable, Identifiable, Hashable {
    /// 轨道种类。
    public enum Kind: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
        /// 音频轨。
        case audio
        /// 字幕轨。
        case subtitle
    }

    /// 轨道 id：引擎/容器内的 stream index（Emby 的 `MediaStream.Index`）。
    ///
    /// - Important: 这是**序号而不是数组下标**。菜单里要显示顺序时请另用数组顺序，
    ///   传给引擎的永远是这里的 `id`。
    public let id: Int

    /// 轨道种类。
    public let kind: Kind

    /// 菜单显示名（引擎给的 `name`，或 Emby 的 `DisplayTitle`）。
    public let title: String

    /// ISO 639-1/2 语言代码。
    public let language: String?

    /// 编解码器名（`aac`、`ac3`、`subrip`、`ass`、`hdmv_pgs_subtitle`…）。
    public let codec: String

    /// 声道数；非音频轨为 0。
    public let channels: Int

    /// 是否为默认轨。
    public let isDefault: Bool

    /// 是否为强制轨（forced）。
    public let isForced: Bool

    /// 是否为外挂轨（外挂字幕 / 外部音轨）。
    public let isExternal: Bool

    /// 是否为**文本**字幕（可调样式、可自绘）。
    ///
    /// 图形字幕（PGS / DVB / VOBSUB）为 `false`——它们只能整张图贴上去，
    /// 字号/颜色这类 ``SubtitleStyle`` 对它们无效。音频轨恒为 `false`。
    public let isTextSubtitle: Bool

    /// 完整初始化。
    ///
    /// - Parameters:
    ///   - id: 轨道 id（stream index）。
    ///   - kind: 轨道种类。
    ///   - title: 显示名。
    ///   - language: 语言代码。
    ///   - codec: 编解码器名。
    ///   - channels: 声道数。
    ///   - isDefault: 是否默认轨。
    ///   - isForced: 是否强制轨。
    ///   - isExternal: 是否外挂轨。
    ///   - isTextSubtitle: 是否文本字幕。
    public init(
        id: Int,
        kind: Kind,
        title: String,
        language: String? = nil,
        codec: String,
        channels: Int = 0,
        isDefault: Bool = false,
        isForced: Bool = false,
        isExternal: Bool = false,
        isTextSubtitle: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.language = language
        self.codec = codec
        self.channels = channels
        self.isDefault = isDefault
        self.isForced = isForced
        self.isExternal = isExternal
        self.isTextSubtitle = isTextSubtitle
    }

    /// 从 Emby 的 ``MediaStream`` 映射；**视频 / 附件 / 内嵌图片 / 数据轨返回 `nil`**。
    ///
    /// 分类规则：
    /// - `Type == Audio` → ``Kind/audio``；
    /// - `Type == Subtitle` → ``Kind/subtitle``，文本/图形判定见 ``isTextSubtitle``；
    /// - 其他（`Video`、`EmbeddedImage`、`Attachment`、`Data`、`Lyric`、未知）→ `nil`。
    ///
    /// - Parameter stream: Emby `PlaybackInfo` 里的媒体流。
    public init?(stream: MediaStream) {
        let kind: Kind
        switch stream.type {
        case .audio: kind = .audio
        case .subtitle: kind = .subtitle
        default: return nil
        }

        self.id = stream.index
        self.kind = kind
        self.title = stream.displayTitle ?? stream.displayName
        self.language = stream.language
        self.codec = stream.codec ?? ""
        self.channels = stream.channels ?? 0
        self.isDefault = stream.isDefault
        self.isForced = stream.isForced
        self.isExternal = stream.isExternal
        switch kind {
        case .audio:
            self.isTextSubtitle = false
        case .subtitle:
            // Emby 的 `IsTextSubtitleStream` 最权威；个别服务器不填时按 codec 兜底。
            self.isTextSubtitle = stream.isTextSubtitleStream
                || !Self.isBitmapSubtitleCodec(stream.codec)
        }
    }

    /// 图形字幕（只能贴图、无法调样式）的 codec 名单。
    ///
    /// 来源：libavcodec 的 subtitle codec 名 + Emby 常见取值（PGS / DVD / DVB / XSUB）。
    public static let bitmapSubtitleCodecs: Set<String> = [
        "hdmv_pgs_subtitle", "pgs", "pgssub",
        "dvd_subtitle", "dvdsub", "vobsub",
        "dvb_subtitle", "dvbsub",
        "xsub", "dvb_teletext"
    ]

    /// 文本字幕 codec 名单（可自绘、可调样式）。
    public static let textSubtitleCodecs: Set<String> = [
        "subrip", "srt", "ass", "ssa", "webvtt", "vtt",
        "mov_text", "text", "microdvd", "sami", "realtext", "subviewer", "subviewer1", "jacosub"
    ]

    /// 判断某个字幕 codec 是否是图形字幕。
    ///
    /// - Parameter codec: codec 名（大小写不敏感）；`nil` 视为非图形。
    public static func isBitmapSubtitleCodec(_ codec: String?) -> Bool {
        guard let codec else { return false }
        return bitmapSubtitleCodecs.contains(codec.lowercased())
    }

    /// 判断某个字幕 codec 是否是文本字幕。
    ///
    /// - Parameter codec: codec 名（大小写不敏感）；`nil` 视为非文本。
    public static func isTextSubtitleCodec(_ codec: String?) -> Bool {
        guard let codec else { return false }
        return textSubtitleCodecs.contains(codec.lowercased())
    }
}
