import Foundation

/// 媒体流（视频轨 / 音频轨 / 字幕轨），对应 Emby `MediaStream`。
///
/// 字段来源（已核实）：<https://dev.emby.media/reference/pluginapi/MediaBrowser.Model.Entities.MediaStream.html>
/// 以及社区实测的 `PlaybackInfo` 返回样例。契约要求的字段全部保留，
/// 另外补上了实际存在且播放协商必需的字段（`isForced`、`isTextSubtitleStream`、
/// `supportsExternalStream`、`protocolName`、`displayLanguage`、`channelLayout`、
/// `sampleRate`、`bitRate`、`profile`、`attachmentSize`、`title`）。
///
/// 所有字段都有默认值：`Index`、`Type` 缺失时退化为 `0` 与 ``StreamType/unknown(_:)``，
/// 不会让整条 `MediaItem` 解码失败。
public struct MediaStream: Sendable, Codable, Hashable, Identifiable {
    /// 流在容器内的序号（播放时用它选中音轨 / 字幕轨）。
    public let index: Int
    /// 流类型。
    public let type: StreamType
    /// 编解码器名（`h264`、`hevc`、`aac`、`subrip`…）。
    public let codec: String?
    /// ISO 639-1/2 语言代码（`eng`、`jpn`、`chi`…）。
    public let language: String?
    /// 展示用标题（Emby 已经拼好，如 “English AAC 5.1 (Default)”）。
    public let displayTitle: String?
    /// 是否为默认轨。
    public let isDefault: Bool
    /// 是否为外挂轨（外挂字幕 / 外部音轨）。
    public let isExternal: Bool
    /// 视频高度（像素）。
    public let height: Int?
    /// 视频宽度（像素）。
    public let width: Int?
    /// 音频声道数。
    public let channels: Int?
    /// 视频动态范围（`SDR` / `HDR10` / `HLG` / `DolbyVision`…）。
    public let videoRange: String?
    /// 外挂字幕 / 音轨的直取地址。
    public let deliveryUrl: String?

    // MARK: - 契约之外、实际存在的字段

    /// 是否为强制字幕轨（forced）。
    public let isForced: Bool
    /// 是否为文本字幕（可渲染、可调样式；PGS/VOBSUB 等图形字幕为 `false`）。
    public let isTextSubtitleStream: Bool
    /// 服务端是否支持以外部流方式提供该轨（外挂字幕下载用）。
    public let supportsExternalStream: Bool
    /// 传输协议（`Http`、`File`、`Rtmp`…），对应 JSON 的 `Protocol`。
    public let protocolName: String?
    /// 本地化语言名（如 “英语”）。
    public let displayLanguage: String?
    /// 声道布局（`5.1`、`stereo`…）。
    public let channelLayout: String?
    /// 音频采样率（Hz）。
    public let sampleRate: Int?
    /// 码率（bps）。
    public let bitRate: Int?
    /// 编码 profile（`High`、`Main 10`、`LC`…）。
    public let profile: String?
    /// 附件大小（字体等，字节）。
    public let attachmentSize: Int?
    /// 轨道标题（容器内的 title 标签）。
    public let title: String?

    /// `Identifiable` 要求；同一媒体源内 `index` 唯一。
    public var id: Int { index }

    /// 完整初始化。
    public init(
        index: Int,
        type: StreamType,
        codec: String? = nil,
        language: String? = nil,
        displayTitle: String? = nil,
        isDefault: Bool = false,
        isExternal: Bool = false,
        height: Int? = nil,
        width: Int? = nil,
        channels: Int? = nil,
        videoRange: String? = nil,
        deliveryUrl: String? = nil,
        isForced: Bool = false,
        isTextSubtitleStream: Bool = false,
        supportsExternalStream: Bool = false,
        protocolName: String? = nil,
        displayLanguage: String? = nil,
        channelLayout: String? = nil,
        sampleRate: Int? = nil,
        bitRate: Int? = nil,
        profile: String? = nil,
        attachmentSize: Int? = nil,
        title: String? = nil
    ) {
        self.index = index
        self.type = type
        self.codec = codec
        self.language = language
        self.displayTitle = displayTitle
        self.isDefault = isDefault
        self.isExternal = isExternal
        self.height = height
        self.width = width
        self.channels = channels
        self.videoRange = videoRange
        self.deliveryUrl = deliveryUrl
        self.isForced = isForced
        self.isTextSubtitleStream = isTextSubtitleStream
        self.supportsExternalStream = supportsExternalStream
        self.protocolName = protocolName
        self.displayLanguage = displayLanguage
        self.channelLayout = channelLayout
        self.sampleRate = sampleRate
        self.bitRate = bitRate
        self.profile = profile
        self.attachmentSize = attachmentSize
        self.title = title
    }

    /// 是否为 HDR 视频轨（`videoRange` 含 `HDR` 或 `Dolby`）。
    public var isHDR: Bool {
        guard let videoRange else { return false }
        let upper = videoRange.uppercased()
        return upper.contains("HDR") || upper.contains("DOLBY")
    }

    /// 展示名：优先 `displayTitle`，其次 `displayLanguage` + `codec`，最后 `codec`。
    public var displayName: String {
        if let displayTitle, !displayTitle.isEmpty { return displayTitle }
        let languagePart = displayLanguage ?? language
        switch (languagePart, codec) {
        case let (language?, codec?): return "\(language) · \(codec)"
        case let (language?, nil): return language
        case let (nil, codec?): return codec
        case (nil, nil): return "Track \(index)"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case index = "Index"
        case type = "Type"
        case codec = "Codec"
        case language = "Language"
        case displayTitle = "DisplayTitle"
        case isDefault = "IsDefault"
        case isExternal = "IsExternal"
        case height = "Height"
        case width = "Width"
        case channels = "Channels"
        case videoRange = "VideoRange"
        case deliveryUrl = "DeliveryUrl"
        case isForced = "IsForced"
        case isTextSubtitleStream = "IsTextSubtitleStream"
        case supportsExternalStream = "SupportsExternalStream"
        case protocolName = "Protocol"
        case displayLanguage = "DisplayLanguage"
        case channelLayout = "ChannelLayout"
        case sampleRate = "SampleRate"
        case bitRate = "BitRate"
        case profile = "Profile"
        case attachmentSize = "AttachmentSize"
        case title = "Title"
    }

    /// 宽松解码：`Index` 缺失按 0 处理，`Type` 缺失按未知类型处理。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.index = container.decodeFlexibleInt(forKey: .index) ?? 0
        self.type = (try? container.decodeIfPresent(StreamType.self, forKey: .type)) ?? .unknown("")
        self.codec = try? container.decodeIfPresent(String.self, forKey: .codec)
        self.language = try? container.decodeIfPresent(String.self, forKey: .language)
        self.displayTitle = try? container.decodeIfPresent(String.self, forKey: .displayTitle)
        self.isDefault = container.decodeFlexibleBool(forKey: .isDefault) ?? false
        self.isExternal = container.decodeFlexibleBool(forKey: .isExternal) ?? false
        self.height = container.decodeFlexibleInt(forKey: .height)
        self.width = container.decodeFlexibleInt(forKey: .width)
        self.channels = container.decodeFlexibleInt(forKey: .channels)
        self.videoRange = try? container.decodeIfPresent(String.self, forKey: .videoRange)
        self.deliveryUrl = try? container.decodeIfPresent(String.self, forKey: .deliveryUrl)
        self.isForced = container.decodeFlexibleBool(forKey: .isForced) ?? false
        self.isTextSubtitleStream = container.decodeFlexibleBool(forKey: .isTextSubtitleStream) ?? false
        self.supportsExternalStream = container.decodeFlexibleBool(forKey: .supportsExternalStream) ?? false
        self.protocolName = try? container.decodeIfPresent(String.self, forKey: .protocolName)
        self.displayLanguage = try? container.decodeIfPresent(String.self, forKey: .displayLanguage)
        self.channelLayout = try? container.decodeIfPresent(String.self, forKey: .channelLayout)
        self.sampleRate = container.decodeFlexibleInt(forKey: .sampleRate)
        self.bitRate = container.decodeFlexibleInt(forKey: .bitRate)
        self.profile = try? container.decodeIfPresent(String.self, forKey: .profile)
        self.attachmentSize = container.decodeFlexibleInt(forKey: .attachmentSize)
        self.title = try? container.decodeIfPresent(String.self, forKey: .title)
    }

    /// 按 Emby 的 PascalCase 字段名编码。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(index, forKey: .index)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(codec, forKey: .codec)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encodeIfPresent(displayTitle, forKey: .displayTitle)
        try container.encode(isDefault, forKey: .isDefault)
        try container.encode(isExternal, forKey: .isExternal)
        try container.encodeIfPresent(height, forKey: .height)
        try container.encodeIfPresent(width, forKey: .width)
        try container.encodeIfPresent(channels, forKey: .channels)
        try container.encodeIfPresent(videoRange, forKey: .videoRange)
        try container.encodeIfPresent(deliveryUrl, forKey: .deliveryUrl)
        try container.encode(isForced, forKey: .isForced)
        try container.encode(isTextSubtitleStream, forKey: .isTextSubtitleStream)
        try container.encode(supportsExternalStream, forKey: .supportsExternalStream)
        try container.encodeIfPresent(protocolName, forKey: .protocolName)
        try container.encodeIfPresent(displayLanguage, forKey: .displayLanguage)
        try container.encodeIfPresent(channelLayout, forKey: .channelLayout)
        try container.encodeIfPresent(sampleRate, forKey: .sampleRate)
        try container.encodeIfPresent(bitRate, forKey: .bitRate)
        try container.encodeIfPresent(profile, forKey: .profile)
        try container.encodeIfPresent(attachmentSize, forKey: .attachmentSize)
        try container.encodeIfPresent(title, forKey: .title)
    }
}
