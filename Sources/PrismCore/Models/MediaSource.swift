import Foundation

/// 媒体源（一个条目可能有多版本：1080p / 4K / 不同音轨版本）。
///
/// 字段来源（已核实）：<https://dev.emby.media/reference/pluginapi/MediaBrowser.Model.Dto.MediaSourceInfo.html>
/// —— `Id`、`Name`、`Container`、`RunTimeTicks`、`Bitrate`、`Size`、`IsRemote`、
/// `DirectStreamUrl`、`TranscodingUrl`、`PlaySessionId`、`MediaStreams`、
/// `SupportsDirectPlay`、`SupportsDirectStream`、`SupportsTranscoding`。
///
/// 契约之外的补充字段（播放协商必需）：`videoType`（`VideoFile`/`Bluray`/`Dvd`/`Iso`）、
/// `protocolName`（`Protocol`）、`defaultAudioStreamIndex`、`defaultSubtitleStreamIndex`。
public struct MediaSource: Sendable, Codable, Hashable, Identifiable {
    /// 媒体源 id，播放 / 进度上报时必须回传。
    public let id: String
    /// 媒体源名（多版本时展示用）。
    public let name: String?
    /// 容器格式（`mkv`、`mp4`、`ts`…）。
    public let container: String?
    /// 时长。
    public let runTime: Ticks?
    /// 总码率（bps）。
    public let bitrate: Int?
    /// 文件大小（字节）。
    public let size: Int64?
    /// 是否为互联网远程源。
    public let isRemote: Bool
    /// 直连播放地址。
    public let directStreamUrl: String?
    /// 转码播放地址。
    public let transcodingUrl: String?
    /// 播放会话 id（进度上报必须带）。
    public let playSessionId: String?
    /// 该源包含的媒体流。
    public let mediaStreams: [MediaStream]
    /// 是否支持直连播放。
    public let supportsDirectPlay: Bool
    /// 是否支持直连封装（remux）。
    public let supportsDirectStream: Bool
    /// 是否支持转码。
    public let supportsTranscoding: Bool

    // MARK: - 契约之外、实际存在的字段

    /// 视频来源类型（`VideoFile`、`Bluray`、`Dvd`、`HdDvd`、`Iso`）。
    public let videoType: String?
    /// 传输协议（`Http`、`File`…），对应 JSON 的 `Protocol`。
    public let protocolName: String?
    /// 默认音轨序号。
    public let defaultAudioStreamIndex: Int?
    /// 默认字幕序号（`-1` 表示关闭）。
    public let defaultSubtitleStreamIndex: Int?

    /// 完整初始化。
    public init(
        id: String,
        name: String? = nil,
        container: String? = nil,
        runTime: Ticks? = nil,
        bitrate: Int? = nil,
        size: Int64? = nil,
        isRemote: Bool = false,
        directStreamUrl: String? = nil,
        transcodingUrl: String? = nil,
        playSessionId: String? = nil,
        mediaStreams: [MediaStream] = [],
        supportsDirectPlay: Bool = false,
        supportsDirectStream: Bool = false,
        supportsTranscoding: Bool = false,
        videoType: String? = nil,
        protocolName: String? = nil,
        defaultAudioStreamIndex: Int? = nil,
        defaultSubtitleStreamIndex: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.container = container
        self.runTime = runTime
        self.bitrate = bitrate
        self.size = size
        self.isRemote = isRemote
        self.directStreamUrl = directStreamUrl
        self.transcodingUrl = transcodingUrl
        self.playSessionId = playSessionId
        self.mediaStreams = mediaStreams
        self.supportsDirectPlay = supportsDirectPlay
        self.supportsDirectStream = supportsDirectStream
        self.supportsTranscoding = supportsTranscoding
        self.videoType = videoType
        self.protocolName = protocolName
        self.defaultAudioStreamIndex = defaultAudioStreamIndex
        self.defaultSubtitleStreamIndex = defaultSubtitleStreamIndex
    }

    /// 按类型筛选媒体流。
    ///
    /// - Parameter type: 目标流类型。
    /// - Returns: 匹配的流（按 `index` 升序）。
    public func streams(ofType type: StreamType) -> [MediaStream] {
        mediaStreams.filter { $0.type == type }.sorted { $0.index < $1.index }
    }

    /// 默认音频轨：优先 `IsDefault`，否则取第一条音频轨。
    public var defaultAudioStream: MediaStream? {
        let audios = streams(ofType: .audio)
        return audios.first(where: \.isDefault) ?? audios.first
    }

    /// 默认字幕轨：优先 `IsDefault`，否则取第一条字幕轨；`-1` 视为关闭。
    public var defaultSubtitleStream: MediaStream? {
        if defaultSubtitleStreamIndex == -1 { return nil }
        let subtitles = streams(ofType: .subtitle)
        if let defaultSubtitleStreamIndex,
           let stream = subtitles.first(where: { $0.index == defaultSubtitleStreamIndex }) {
            return stream
        }
        return subtitles.first(where: \.isDefault) ?? subtitles.first
    }

    /// 视频轨（第一条）。
    public var videoStream: MediaStream? {
        mediaStreams.first { $0.type == .video }
    }

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case container = "Container"
        case runTime = "RunTimeTicks"
        case bitrate = "Bitrate"
        case size = "Size"
        case isRemote = "IsRemote"
        case directStreamUrl = "DirectStreamUrl"
        case transcodingUrl = "TranscodingUrl"
        case playSessionId = "PlaySessionId"
        case mediaStreams = "MediaStreams"
        case supportsDirectPlay = "SupportsDirectPlay"
        case supportsDirectStream = "SupportsDirectStream"
        case supportsTranscoding = "SupportsTranscoding"
        case videoType = "VideoType"
        case protocolName = "Protocol"
        case defaultAudioStreamIndex = "DefaultAudioStreamIndex"
        case defaultSubtitleStreamIndex = "DefaultSubtitleStreamIndex"
    }

    /// 宽松解码：`Id` 缺失时退化为空串，其余字段缺失一律取默认值。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = container.decodeFlexibleString(forKey: .id) ?? ""
        self.name = try? container.decodeIfPresent(String.self, forKey: .name)
        self.container = try? container.decodeIfPresent(String.self, forKey: .container)
        self.runTime = container.decodeTicksIfPresent(forKey: .runTime)
        self.bitrate = container.decodeFlexibleInt(forKey: .bitrate)
        self.size = container.decodeFlexibleInt64(forKey: .size)
        self.isRemote = container.decodeFlexibleBool(forKey: .isRemote) ?? false
        self.directStreamUrl = try? container.decodeIfPresent(String.self, forKey: .directStreamUrl)
        self.transcodingUrl = try? container.decodeIfPresent(String.self, forKey: .transcodingUrl)
        self.playSessionId = try? container.decodeIfPresent(String.self, forKey: .playSessionId)
        self.mediaStreams = container.decodeLossyArray(MediaStream.self, forKey: .mediaStreams)
        self.supportsDirectPlay = container.decodeFlexibleBool(forKey: .supportsDirectPlay) ?? false
        self.supportsDirectStream = container.decodeFlexibleBool(forKey: .supportsDirectStream) ?? false
        self.supportsTranscoding = container.decodeFlexibleBool(forKey: .supportsTranscoding) ?? false
        self.videoType = try? container.decodeIfPresent(String.self, forKey: .videoType)
        self.protocolName = try? container.decodeIfPresent(String.self, forKey: .protocolName)
        self.defaultAudioStreamIndex = container.decodeFlexibleInt(forKey: .defaultAudioStreamIndex)
        self.defaultSubtitleStreamIndex = container.decodeFlexibleInt(forKey: .defaultSubtitleStreamIndex)
    }

    /// 按 Emby 的 PascalCase 字段名编码。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(self.container, forKey: .container)
        try container.encodeIfPresent(runTime, forKey: .runTime)
        try container.encodeIfPresent(bitrate, forKey: .bitrate)
        try container.encodeIfPresent(size, forKey: .size)
        try container.encode(isRemote, forKey: .isRemote)
        try container.encodeIfPresent(directStreamUrl, forKey: .directStreamUrl)
        try container.encodeIfPresent(transcodingUrl, forKey: .transcodingUrl)
        try container.encodeIfPresent(playSessionId, forKey: .playSessionId)
        try container.encode(mediaStreams, forKey: .mediaStreams)
        try container.encode(supportsDirectPlay, forKey: .supportsDirectPlay)
        try container.encode(supportsDirectStream, forKey: .supportsDirectStream)
        try container.encode(supportsTranscoding, forKey: .supportsTranscoding)
        try container.encodeIfPresent(videoType, forKey: .videoType)
        try container.encodeIfPresent(protocolName, forKey: .protocolName)
        try container.encodeIfPresent(defaultAudioStreamIndex, forKey: .defaultAudioStreamIndex)
        try container.encodeIfPresent(defaultSubtitleStreamIndex, forKey: .defaultSubtitleStreamIndex)
    }
}
