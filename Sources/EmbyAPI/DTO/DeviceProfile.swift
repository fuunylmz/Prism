import Foundation

/// 客户端能力描述，对应 Emby 的 `MediaBrowser.Model.Dlna.DeviceProfile`。
///
/// 字段来源（已核实）：<https://dev.emby.media/reference/RestAPI/MediaInfoService/postItemsByIdPlaybackinfo.html>
/// 的 Definitions 段（当前版本代码生成）与
/// <https://dev.emby.media/reference/pluginapi/MediaBrowser.Model.Dlna.DeviceProfile.html>。
///
/// ## 设计要点
///
/// 1. 只建模客户端真正需要的字段。官方明确说明 DLNA 专属属性
///    （`ProtocolInfo`、`Manufacturer`、`ModelName`…）可以全部省略
///    （<https://dev.emby.media/doc/restapi/Sync.html>：“For brevity, all Dlna-specific
///    properties such as ProtocolInfo, Manufacturer/Model, etc. can be omitted.”）。
/// 2. **空数组 / `nil` 字段不编码**，让请求体尽量小且与真实客户端一致。
/// 3. 所有子结构都能容错解码（虽然本类型主要用于「请求体编码」，测试里要能往返）。
///
/// ## 现成的 macOS 能力描述
///
/// 直接用 ``prismMacOS(maxStreamingBitrate:)``，不要自己拼：
/// ```swift
/// let info = try await client.send(
///     PlaybackInfoEndpoint(itemId: id, userId: uid, profile: .prismMacOS())
/// )
/// ```
public struct DeviceProfile: Sendable, Codable, Hashable {
    /// 能力描述名（服务端日志里可见）。
    public var name: String

    /// 能力描述 id。
    public var id: String?

    /// 支持的媒体大类，逗号分隔（如 `"Audio,Video,Photo"`）。
    public var supportedMediaTypes: String?

    /// 流媒体码率上限（bps）。
    public var maxStreamingBitrate: Int64?

    /// 静态（非流式）码率上限（bps）。
    ///
    /// 【待验证】当前 `PlaybackInfo` Reference 的 `DeviceProfile` 定义里**没有**该字段，
    /// 但 jellyfin-web 与旧版 Emby schema 都会发；多传对 .NET 反序列化无副作用。
    public var maxStaticBitrate: Int64?

    /// 音乐转码码率上限（bps）。
    public var musicStreamingTranscodingBitrate: Int?

    /// 静态音乐码率上限（bps）。
    public var maxStaticMusicBitrate: Int?

    /// 直连播放能力。
    public var directPlayProfiles: [DirectPlayProfile]

    /// 转码能力。
    public var transcodingProfiles: [TranscodingProfile]

    /// 容器限制（通常为空）。
    public var containerProfiles: [ContainerProfile]

    /// 编解码限制（决定「什么情况下必须转码」）。
    public var codecProfiles: [CodecProfile]

    /// 响应配置（通常为空）。
    public var responseProfiles: [ResponseProfile]

    /// 字幕能力。
    public var subtitleProfiles: [SubtitleProfile]

    /// 完整初始化（除 `name` 外全部有默认值）。
    ///
    /// - Parameters:
    ///   - name: 能力描述名。
    ///   - id: 能力描述 id。
    ///   - supportedMediaTypes: 支持的媒体大类。
    ///   - maxStreamingBitrate: 流媒体码率上限。
    ///   - maxStaticBitrate: 静态码率上限。
    ///   - musicStreamingTranscodingBitrate: 音乐转码码率上限。
    ///   - maxStaticMusicBitrate: 静态音乐码率上限。
    ///   - directPlayProfiles: 直连能力。
    ///   - transcodingProfiles: 转码能力。
    ///   - containerProfiles: 容器限制。
    ///   - codecProfiles: 编解码限制。
    ///   - responseProfiles: 响应配置。
    ///   - subtitleProfiles: 字幕能力。
    public init(
        name: String = "Prism macOS",
        id: String? = nil,
        supportedMediaTypes: String? = nil,
        maxStreamingBitrate: Int64? = nil,
        maxStaticBitrate: Int64? = nil,
        musicStreamingTranscodingBitrate: Int? = nil,
        maxStaticMusicBitrate: Int? = nil,
        directPlayProfiles: [DirectPlayProfile] = [],
        transcodingProfiles: [TranscodingProfile] = [],
        containerProfiles: [ContainerProfile] = [],
        codecProfiles: [CodecProfile] = [],
        responseProfiles: [ResponseProfile] = [],
        subtitleProfiles: [SubtitleProfile] = []
    ) {
        self.name = name
        self.id = id
        self.supportedMediaTypes = supportedMediaTypes
        self.maxStreamingBitrate = maxStreamingBitrate
        self.maxStaticBitrate = maxStaticBitrate
        self.musicStreamingTranscodingBitrate = musicStreamingTranscodingBitrate
        self.maxStaticMusicBitrate = maxStaticMusicBitrate
        self.directPlayProfiles = directPlayProfiles
        self.transcodingProfiles = transcodingProfiles
        self.containerProfiles = containerProfiles
        self.codecProfiles = codecProfiles
        self.responseProfiles = responseProfiles
        self.subtitleProfiles = subtitleProfiles
    }

    private enum CodingKeys: String, CodingKey {
        case name = "Name"
        case id = "Id"
        case supportedMediaTypes = "SupportedMediaTypes"
        case maxStreamingBitrate = "MaxStreamingBitrate"
        case maxStaticBitrate = "MaxStaticBitrate"
        case musicStreamingTranscodingBitrate = "MusicStreamingTranscodingBitrate"
        case maxStaticMusicBitrate = "MaxStaticMusicBitrate"
        case directPlayProfiles = "DirectPlayProfiles"
        case transcodingProfiles = "TranscodingProfiles"
        case containerProfiles = "ContainerProfiles"
        case codecProfiles = "CodecProfiles"
        case responseProfiles = "ResponseProfiles"
        case subtitleProfiles = "SubtitleProfiles"
    }

    /// 宽松解码：字段缺失退化为空值 / 空数组。
    ///
    /// - Parameter decoder: 解码器。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = container.embyString(forKey: .name) ?? ""
        self.id = container.embyString(forKey: .id)
        self.supportedMediaTypes = container.embyString(forKey: .supportedMediaTypes)
        self.maxStreamingBitrate = container.embyInt64(forKey: .maxStreamingBitrate)
        self.maxStaticBitrate = container.embyInt64(forKey: .maxStaticBitrate)
        self.musicStreamingTranscodingBitrate = container.embyInt(forKey: .musicStreamingTranscodingBitrate)
        self.maxStaticMusicBitrate = container.embyInt(forKey: .maxStaticMusicBitrate)
        self.directPlayProfiles = container.embyArray(DirectPlayProfile.self, forKey: .directPlayProfiles)
        self.transcodingProfiles = container.embyArray(TranscodingProfile.self, forKey: .transcodingProfiles)
        self.containerProfiles = container.embyArray(ContainerProfile.self, forKey: .containerProfiles)
        self.codecProfiles = container.embyArray(CodecProfile.self, forKey: .codecProfiles)
        self.responseProfiles = container.embyArray(ResponseProfile.self, forKey: .responseProfiles)
        self.subtitleProfiles = container.embyArray(SubtitleProfile.self, forKey: .subtitleProfiles)
    }

    /// 按 Emby 的 PascalCase 字段名编码；`nil` 与空数组不写入。
    ///
    /// - Parameter encoder: 编码器。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(supportedMediaTypes, forKey: .supportedMediaTypes)
        try container.encodeIfPresent(maxStreamingBitrate, forKey: .maxStreamingBitrate)
        try container.encodeIfPresent(maxStaticBitrate, forKey: .maxStaticBitrate)
        try container.encodeIfPresent(musicStreamingTranscodingBitrate, forKey: .musicStreamingTranscodingBitrate)
        try container.encodeIfPresent(maxStaticMusicBitrate, forKey: .maxStaticMusicBitrate)
        if !directPlayProfiles.isEmpty { try container.encode(directPlayProfiles, forKey: .directPlayProfiles) }
        if !transcodingProfiles.isEmpty { try container.encode(transcodingProfiles, forKey: .transcodingProfiles) }
        if !containerProfiles.isEmpty { try container.encode(containerProfiles, forKey: .containerProfiles) }
        if !codecProfiles.isEmpty { try container.encode(codecProfiles, forKey: .codecProfiles) }
        if !responseProfiles.isEmpty { try container.encode(responseProfiles, forKey: .responseProfiles) }
        if !subtitleProfiles.isEmpty { try container.encode(subtitleProfiles, forKey: .subtitleProfiles) }
    }
}

// MARK: - 子结构

/// 直连播放能力，对应 `DirectPlayProfile`。
///
/// 字段来源（已核实）：<https://dev.emby.media/reference/RestAPI/MediaInfoService/postItemsByIdPlaybackinfo.html>
/// —— `Container`、`AudioCodec`、`VideoCodec`、`Type`（三者都是**逗号分隔**的列表字符串）。
public struct DirectPlayProfile: Sendable, Codable, Hashable {
    /// 容器列表，逗号分隔（如 `"mp4,m4v"`）。
    public var container: String?
    /// 音频编码列表，逗号分隔（如 `"aac,ac3,eac3"`）。
    public var audioCodec: String?
    /// 视频编码列表，逗号分隔（如 `"h264,hevc"`）。
    public var videoCodec: String?
    /// 媒体大类。
    public var type: DlnaProfileType?

    /// 完整初始化。
    ///
    /// - Parameters:
    ///   - container: 容器列表。
    ///   - audioCodec: 音频编码列表。
    ///   - videoCodec: 视频编码列表。
    ///   - type: 媒体大类。
    public init(
        container: String? = nil,
        audioCodec: String? = nil,
        videoCodec: String? = nil,
        type: DlnaProfileType? = nil
    ) {
        self.container = container
        self.audioCodec = audioCodec
        self.videoCodec = videoCodec
        self.type = type
    }

    private enum CodingKeys: String, CodingKey {
        case container = "Container"
        case audioCodec = "AudioCodec"
        case videoCodec = "VideoCodec"
        case type = "Type"
    }

    /// 宽松解码。
    ///
    /// - Parameter decoder: 解码器。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.container = container.embyString(forKey: .container)
        self.audioCodec = container.embyString(forKey: .audioCodec)
        self.videoCodec = container.embyString(forKey: .videoCodec)
        let raw = container.embyString(forKey: .type) ?? ""
        self.type = raw.isEmpty ? nil : DlnaProfileType(rawValue: raw)
    }

    /// 编码为 PascalCase。
    ///
    /// - Parameter encoder: 编码器。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.container, forKey: .container)
        try container.encodeIfPresent(audioCodec, forKey: .audioCodec)
        try container.encodeIfPresent(videoCodec, forKey: .videoCodec)
        try container.encodeIfPresent(type?.rawValue, forKey: .type)
    }
}

/// 转码能力，对应 `TranscodingProfile`。
///
/// 字段来源（已核实）：<https://dev.emby.media/reference/RestAPI/MediaInfoService/postItemsByIdPlaybackinfo.html>
/// —— `Container`、`Type`、`VideoCodec`、`AudioCodec`、`Protocol`、`EstimateContentLength`、
/// `EnableMpegtsM2TsMode`、`TranscodeSeekInfo`、`CopyTimestamps`、`Context`、
/// `MaxAudioChannels`（**字符串**）、`MinSegments`、`SegmentLength`、`BreakOnNonKeyFrames`、
/// `AllowInterlacedVideoStreamCopy`、`ManifestSubtitles`、`MaxManifestSubtitles`、
/// `MaxWidth`、`MaxHeight`、`FillEmptySubtitleSegments`。
public struct TranscodingProfile: Sendable, Codable, Hashable {
    /// 输出容器（`ts`、`mp4`、`mp3`…）。
    public var container: String?
    /// 媒体大类。
    public var type: DlnaProfileType?
    /// 输出视频编码。
    public var videoCodec: String?
    /// 输出音频编码。
    public var audioCodec: String?
    /// 传输协议（`hls` / `http`）。
    public var protocolName: String?
    /// 转码上下文（`Streaming` / `Static`）。
    public var context: EncodingContext?
    /// 最大声道数。**注意是字符串**（服务端 schema 就是 `string`）。
    public var maxAudioChannels: String?
    /// HLS 起播最小分片数。
    public var minSegments: Int?
    /// 分片时长（秒）。
    public var segmentLength: Int?
    /// 是否在非关键帧处切分。
    public var breakOnNonKeyFrames: Bool?
    /// 是否估算 `Content-Length`。
    public var estimateContentLength: Bool?
    /// 是否启用 MPEG-TS M2TS 模式。
    public var enableMpegtsM2TsMode: Bool?
    /// seek 策略。
    public var transcodeSeekInfo: TranscodeSeekInfo?
    /// 是否复制时间戳。
    public var copyTimestamps: Bool?
    /// 清单字幕格式（如 `"vtt"`）。
    public var manifestSubtitles: String?
    /// 清单字幕最大数量。
    public var maxManifestSubtitles: Int?
    /// 最大宽度。
    public var maxWidth: Int?
    /// 最大高度。
    public var maxHeight: Int?
    /// 是否填充空字幕分片。
    public var fillEmptySubtitleSegments: Bool?
    /// 是否允许隔行视频流拷贝。
    public var allowInterlacedVideoStreamCopy: Bool?

    /// 完整初始化（全部有默认值）。
    ///
    /// - Parameters:
    ///   - container: 输出容器。
    ///   - type: 媒体大类。
    ///   - videoCodec: 输出视频编码。
    ///   - audioCodec: 输出音频编码。
    ///   - protocol: 传输协议。
    ///   - context: 转码上下文。
    ///   - maxAudioChannels: 最大声道数（字符串）。
    ///   - minSegments: HLS 起播最小分片数。
    ///   - segmentLength: 分片时长（秒）。
    ///   - breakOnNonKeyFrames: 是否在非关键帧切分。
    ///   - estimateContentLength: 是否估算长度。
    ///   - enableMpegtsM2TsMode: 是否启用 M2TS 模式。
    ///   - transcodeSeekInfo: seek 策略。
    ///   - copyTimestamps: 是否复制时间戳。
    ///   - manifestSubtitles: 清单字幕格式。
    ///   - maxManifestSubtitles: 清单字幕最大数量。
    ///   - maxWidth: 最大宽度。
    ///   - maxHeight: 最大高度。
    ///   - fillEmptySubtitleSegments: 是否填充空字幕分片。
    ///   - allowInterlacedVideoStreamCopy: 是否允许隔行流拷贝。
    public init(
        container: String? = nil,
        type: DlnaProfileType? = nil,
        videoCodec: String? = nil,
        audioCodec: String? = nil,
        protocolName: String? = nil,
        context: EncodingContext? = nil,
        maxAudioChannels: String? = nil,
        minSegments: Int? = nil,
        segmentLength: Int? = nil,
        breakOnNonKeyFrames: Bool? = nil,
        estimateContentLength: Bool? = nil,
        enableMpegtsM2TsMode: Bool? = nil,
        transcodeSeekInfo: TranscodeSeekInfo? = nil,
        copyTimestamps: Bool? = nil,
        manifestSubtitles: String? = nil,
        maxManifestSubtitles: Int? = nil,
        maxWidth: Int? = nil,
        maxHeight: Int? = nil,
        fillEmptySubtitleSegments: Bool? = nil,
        allowInterlacedVideoStreamCopy: Bool? = nil
    ) {
        self.container = container
        self.type = type
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.protocolName = protocolName
        self.context = context
        self.maxAudioChannels = maxAudioChannels
        self.minSegments = minSegments
        self.segmentLength = segmentLength
        self.breakOnNonKeyFrames = breakOnNonKeyFrames
        self.estimateContentLength = estimateContentLength
        self.enableMpegtsM2TsMode = enableMpegtsM2TsMode
        self.transcodeSeekInfo = transcodeSeekInfo
        self.copyTimestamps = copyTimestamps
        self.manifestSubtitles = manifestSubtitles
        self.maxManifestSubtitles = maxManifestSubtitles
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.fillEmptySubtitleSegments = fillEmptySubtitleSegments
        self.allowInterlacedVideoStreamCopy = allowInterlacedVideoStreamCopy
    }

    private enum CodingKeys: String, CodingKey {
        case container = "Container"
        case type = "Type"
        case videoCodec = "VideoCodec"
        case audioCodec = "AudioCodec"
        case protocolName = "Protocol"
        case context = "Context"
        case maxAudioChannels = "MaxAudioChannels"
        case minSegments = "MinSegments"
        case segmentLength = "SegmentLength"
        case breakOnNonKeyFrames = "BreakOnNonKeyFrames"
        case estimateContentLength = "EstimateContentLength"
        case enableMpegtsM2TsMode = "EnableMpegtsM2TsMode"
        case transcodeSeekInfo = "TranscodeSeekInfo"
        case copyTimestamps = "CopyTimestamps"
        case manifestSubtitles = "ManifestSubtitles"
        case maxManifestSubtitles = "MaxManifestSubtitles"
        case maxWidth = "MaxWidth"
        case maxHeight = "MaxHeight"
        case fillEmptySubtitleSegments = "FillEmptySubtitleSegments"
        case allowInterlacedVideoStreamCopy = "AllowInterlacedVideoStreamCopy"
    }

    /// 宽松解码。
    ///
    /// - Parameter decoder: 解码器。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.container = container.embyString(forKey: .container)
        let rawType = container.embyString(forKey: .type) ?? ""
        self.type = rawType.isEmpty ? nil : DlnaProfileType(rawValue: rawType)
        self.videoCodec = container.embyString(forKey: .videoCodec)
        self.audioCodec = container.embyString(forKey: .audioCodec)
        self.protocolName = container.embyString(forKey: .protocolName)
        let rawContext = container.embyString(forKey: .context) ?? ""
        self.context = rawContext.isEmpty ? nil : EncodingContext(rawValue: rawContext)
        self.maxAudioChannels = container.embyString(forKey: .maxAudioChannels)
        self.minSegments = container.embyInt(forKey: .minSegments)
        self.segmentLength = container.embyInt(forKey: .segmentLength)
        self.breakOnNonKeyFrames = container.embyBool(forKey: .breakOnNonKeyFrames)
        self.estimateContentLength = container.embyBool(forKey: .estimateContentLength)
        self.enableMpegtsM2TsMode = container.embyBool(forKey: .enableMpegtsM2TsMode)
        let rawSeek = container.embyString(forKey: .transcodeSeekInfo) ?? ""
        self.transcodeSeekInfo = rawSeek.isEmpty ? nil : TranscodeSeekInfo(rawValue: rawSeek)
        self.copyTimestamps = container.embyBool(forKey: .copyTimestamps)
        self.manifestSubtitles = container.embyString(forKey: .manifestSubtitles)
        self.maxManifestSubtitles = container.embyInt(forKey: .maxManifestSubtitles)
        self.maxWidth = container.embyInt(forKey: .maxWidth)
        self.maxHeight = container.embyInt(forKey: .maxHeight)
        self.fillEmptySubtitleSegments = container.embyBool(forKey: .fillEmptySubtitleSegments)
        self.allowInterlacedVideoStreamCopy = container.embyBool(forKey: .allowInterlacedVideoStreamCopy)
    }

    /// 编码为 PascalCase；`nil` 不写入。
    ///
    /// - Parameter encoder: 编码器。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.container, forKey: .container)
        try container.encodeIfPresent(type?.rawValue, forKey: .type)
        try container.encodeIfPresent(videoCodec, forKey: .videoCodec)
        try container.encodeIfPresent(audioCodec, forKey: .audioCodec)
        try container.encodeIfPresent(protocolName, forKey: .protocolName)
        try container.encodeIfPresent(context?.rawValue, forKey: .context)
        try container.encodeIfPresent(maxAudioChannels, forKey: .maxAudioChannels)
        try container.encodeIfPresent(minSegments, forKey: .minSegments)
        try container.encodeIfPresent(segmentLength, forKey: .segmentLength)
        try container.encodeIfPresent(breakOnNonKeyFrames, forKey: .breakOnNonKeyFrames)
        try container.encodeIfPresent(estimateContentLength, forKey: .estimateContentLength)
        try container.encodeIfPresent(enableMpegtsM2TsMode, forKey: .enableMpegtsM2TsMode)
        try container.encodeIfPresent(transcodeSeekInfo?.rawValue, forKey: .transcodeSeekInfo)
        try container.encodeIfPresent(copyTimestamps, forKey: .copyTimestamps)
        try container.encodeIfPresent(manifestSubtitles, forKey: .manifestSubtitles)
        try container.encodeIfPresent(maxManifestSubtitles, forKey: .maxManifestSubtitles)
        try container.encodeIfPresent(maxWidth, forKey: .maxWidth)
        try container.encodeIfPresent(maxHeight, forKey: .maxHeight)
        try container.encodeIfPresent(fillEmptySubtitleSegments, forKey: .fillEmptySubtitleSegments)
        try container.encodeIfPresent(allowInterlacedVideoStreamCopy, forKey: .allowInterlacedVideoStreamCopy)
    }
}

/// 容器限制，对应 `ContainerProfile`。
///
/// 字段来源（已核实）：<https://dev.emby.media/reference/RestAPI/MediaInfoService/postItemsByIdPlaybackinfo.html>
/// —— `Type`、`Conditions`、`Container`。
public struct ContainerProfile: Sendable, Codable, Hashable {
    /// 媒体大类。
    public var type: DlnaProfileType?
    /// 条件列表。
    public var conditions: [ProfileCondition]
    /// 容器名。
    public var container: String?

    /// 完整初始化。
    ///
    /// - Parameters:
    ///   - type: 媒体大类。
    ///   - conditions: 条件列表。
    ///   - container: 容器名。
    public init(type: DlnaProfileType? = nil, conditions: [ProfileCondition] = [], container: String? = nil) {
        self.type = type
        self.conditions = conditions
        self.container = container
    }

    private enum CodingKeys: String, CodingKey {
        case type = "Type"
        case conditions = "Conditions"
        case container = "Container"
    }

    /// 宽松解码。
    ///
    /// - Parameter decoder: 解码器。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = container.embyString(forKey: .type) ?? ""
        self.type = rawType.isEmpty ? nil : DlnaProfileType(rawValue: rawType)
        self.conditions = container.embyArray(ProfileCondition.self, forKey: .conditions)
        self.container = container.embyString(forKey: .container)
    }

    /// 编码为 PascalCase。
    ///
    /// - Parameter encoder: 编码器。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(type?.rawValue, forKey: .type)
        if !conditions.isEmpty { try container.encode(conditions, forKey: .conditions) }
        try container.encodeIfPresent(self.container, forKey: .container)
    }
}

/// 编解码限制，对应 `CodecProfile`。
///
/// 字段来源（已核实）：<https://dev.emby.media/reference/RestAPI/MediaInfoService/postItemsByIdPlaybackinfo.html>
/// —— `Type`、`Conditions`、`ApplyConditions`、`Codec`、`Container`。
///
/// 语义：`Conditions` 不满足时**触发转码**；`ApplyConditions` 只影响决策、不直接决定转码。
public struct CodecProfile: Sendable, Codable, Hashable {
    /// 编解码类型（`Video` / `VideoAudio` / `Audio`）。
    public var type: CodecType?
    /// 触发转码的条件。
    public var conditions: [ProfileCondition]
    /// 仅用于决策的条件。
    public var applyConditions: [ProfileCondition]
    /// 编解码器名（省略表示适用所有）。
    public var codec: String?
    /// 容器名。
    public var container: String?

    /// 完整初始化。
    ///
    /// - Parameters:
    ///   - type: 编解码类型。
    ///   - conditions: 触发转码的条件。
    ///   - applyConditions: 仅用于决策的条件。
    ///   - codec: 编解码器名。
    ///   - container: 容器名。
    public init(
        type: CodecType? = nil,
        conditions: [ProfileCondition] = [],
        applyConditions: [ProfileCondition] = [],
        codec: String? = nil,
        container: String? = nil
    ) {
        self.type = type
        self.conditions = conditions
        self.applyConditions = applyConditions
        self.codec = codec
        self.container = container
    }

    private enum CodingKeys: String, CodingKey {
        case type = "Type"
        case conditions = "Conditions"
        case applyConditions = "ApplyConditions"
        case codec = "Codec"
        case container = "Container"
    }

    /// 宽松解码。
    ///
    /// - Parameter decoder: 解码器。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = container.embyString(forKey: .type) ?? ""
        self.type = rawType.isEmpty ? nil : CodecType(rawValue: rawType)
        self.conditions = container.embyArray(ProfileCondition.self, forKey: .conditions)
        self.applyConditions = container.embyArray(ProfileCondition.self, forKey: .applyConditions)
        self.codec = container.embyString(forKey: .codec)
        self.container = container.embyString(forKey: .container)
    }

    /// 编码为 PascalCase。
    ///
    /// - Parameter encoder: 编码器。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(type?.rawValue, forKey: .type)
        if !conditions.isEmpty { try container.encode(conditions, forKey: .conditions) }
        if !applyConditions.isEmpty { try container.encode(applyConditions, forKey: .applyConditions) }
        try container.encodeIfPresent(codec, forKey: .codec)
        try container.encodeIfPresent(self.container, forKey: .container)
    }
}

/// 响应配置，对应 `ResponseProfile`。
///
/// 字段来源（已核实）：<https://dev.emby.media/reference/RestAPI/MediaInfoService/postItemsByIdPlaybackinfo.html>
/// —— `Container`、`AudioCodec`、`VideoCodec`、`Type`、`OrgPn`、`MimeType`、`Conditions`。
public struct ResponseProfile: Sendable, Codable, Hashable {
    /// 容器名。
    public var container: String?
    /// 音频编码。
    public var audioCodec: String?
    /// 视频编码。
    public var videoCodec: String?
    /// 媒体大类。
    public var type: DlnaProfileType?
    /// DLNA `org.pn` 值。
    public var orgPn: String?
    /// MIME 类型。
    public var mimeType: String?
    /// 条件列表。
    public var conditions: [ProfileCondition]

    /// 完整初始化。
    ///
    /// - Parameters:
    ///   - container: 容器名。
    ///   - audioCodec: 音频编码。
    ///   - videoCodec: 视频编码。
    ///   - type: 媒体大类。
    ///   - orgPn: DLNA org.pn。
    ///   - mimeType: MIME 类型。
    ///   - conditions: 条件列表。
    public init(
        container: String? = nil,
        audioCodec: String? = nil,
        videoCodec: String? = nil,
        type: DlnaProfileType? = nil,
        orgPn: String? = nil,
        mimeType: String? = nil,
        conditions: [ProfileCondition] = []
    ) {
        self.container = container
        self.audioCodec = audioCodec
        self.videoCodec = videoCodec
        self.type = type
        self.orgPn = orgPn
        self.mimeType = mimeType
        self.conditions = conditions
    }

    private enum CodingKeys: String, CodingKey {
        case container = "Container"
        case audioCodec = "AudioCodec"
        case videoCodec = "VideoCodec"
        case type = "Type"
        case orgPn = "OrgPn"
        case mimeType = "MimeType"
        case conditions = "Conditions"
    }

    /// 宽松解码。
    ///
    /// - Parameter decoder: 解码器。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.container = container.embyString(forKey: .container)
        self.audioCodec = container.embyString(forKey: .audioCodec)
        self.videoCodec = container.embyString(forKey: .videoCodec)
        let rawType = container.embyString(forKey: .type) ?? ""
        self.type = rawType.isEmpty ? nil : DlnaProfileType(rawValue: rawType)
        self.orgPn = container.embyString(forKey: .orgPn)
        self.mimeType = container.embyString(forKey: .mimeType)
        self.conditions = container.embyArray(ProfileCondition.self, forKey: .conditions)
    }

    /// 编码为 PascalCase。
    ///
    /// - Parameter encoder: 编码器。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.container, forKey: .container)
        try container.encodeIfPresent(audioCodec, forKey: .audioCodec)
        try container.encodeIfPresent(videoCodec, forKey: .videoCodec)
        try container.encodeIfPresent(type?.rawValue, forKey: .type)
        try container.encodeIfPresent(orgPn, forKey: .orgPn)
        try container.encodeIfPresent(mimeType, forKey: .mimeType)
        if !conditions.isEmpty { try container.encode(conditions, forKey: .conditions) }
    }
}

/// 字幕能力，对应 `SubtitleProfile`。
///
/// 字段来源（已核实）：<https://dev.emby.media/reference/RestAPI/MediaInfoService/postItemsByIdPlaybackinfo.html>
/// —— `Format`、`Method`、`DidlMode`、`Language`、`Container`、`AllowChunkedResponse`、`Protocol`。
public struct SubtitleProfile: Sendable, Codable, Hashable {
    /// 字幕格式（`vtt`、`ass`、`srt`、`pgssub`…）。
    public var format: String?
    /// 交付方式（`Encode` 烧录 / `Embed` 封装 / `External` 外挂 / `Hls`）。
    public var method: SubtitleDeliveryMethod?
    /// DLNA 模式，客户端可省略。
    public var didlMode: String?
    /// 语言限制。
    public var language: String?
    /// 容器限制。
    public var container: String?
    /// 是否允许分块响应。
    public var allowChunkedResponse: Bool?
    /// 协议。
    public var protocolName: String?

    /// 完整初始化。
    ///
    /// - Parameters:
    ///   - format: 字幕格式。
    ///   - method: 交付方式。
    ///   - didlMode: DLNA 模式。
    ///   - language: 语言限制。
    ///   - container: 容器限制。
    ///   - allowChunkedResponse: 是否允许分块响应。
    ///   - protocol: 协议。
    public init(
        format: String? = nil,
        method: SubtitleDeliveryMethod? = nil,
        didlMode: String? = nil,
        language: String? = nil,
        container: String? = nil,
        allowChunkedResponse: Bool? = nil,
        protocolName: String? = nil
    ) {
        self.format = format
        self.method = method
        self.didlMode = didlMode
        self.language = language
        self.container = container
        self.allowChunkedResponse = allowChunkedResponse
        self.protocolName = protocolName
    }

    private enum CodingKeys: String, CodingKey {
        case format = "Format"
        case method = "Method"
        case didlMode = "DidlMode"
        case language = "Language"
        case container = "Container"
        case allowChunkedResponse = "AllowChunkedResponse"
        case protocolName = "Protocol"
    }

    /// 宽松解码。
    ///
    /// - Parameter decoder: 解码器。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.format = container.embyString(forKey: .format)
        let rawMethod = container.embyString(forKey: .method) ?? ""
        self.method = rawMethod.isEmpty ? nil : SubtitleDeliveryMethod(rawValue: rawMethod)
        self.didlMode = container.embyString(forKey: .didlMode)
        self.language = container.embyString(forKey: .language)
        self.container = container.embyString(forKey: .container)
        self.allowChunkedResponse = container.embyBool(forKey: .allowChunkedResponse)
        self.protocolName = container.embyString(forKey: .protocolName)
    }

    /// 编码为 PascalCase。
    ///
    /// - Parameter encoder: 编码器。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(format, forKey: .format)
        try container.encodeIfPresent(method?.rawValue, forKey: .method)
        try container.encodeIfPresent(didlMode, forKey: .didlMode)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encodeIfPresent(self.container, forKey: .container)
        try container.encodeIfPresent(allowChunkedResponse, forKey: .allowChunkedResponse)
        try container.encodeIfPresent(protocolName, forKey: .protocolName)
    }
}

/// 单项条件，对应 `ProfileCondition`。
///
/// 字段来源（已核实）：<https://dev.emby.media/reference/RestAPI/MediaInfoService/postItemsByIdPlaybackinfo.html>
/// —— `Condition`、`Property`、`Value`、`IsRequired`。
///
/// `IsRequired == true` 表示条件不满足即转码；`false` 表示不满足也可播。
public struct ProfileCondition: Sendable, Codable, Hashable {
    /// 比较方式。
    public var condition: ProfileConditionType?
    /// 被比较的属性。
    public var property: ProfileConditionValue?
    /// 比较值（字符串，服务端自己按属性类型解析）。
    public var value: String?
    /// 是否为硬性条件。
    public var isRequired: Bool?

    /// 完整初始化。
    ///
    /// - Parameters:
    ///   - condition: 比较方式。
    ///   - property: 被比较的属性。
    ///   - value: 比较值。
    ///   - isRequired: 是否为硬性条件。
    public init(
        condition: ProfileConditionType? = nil,
        property: ProfileConditionValue? = nil,
        value: String? = nil,
        isRequired: Bool? = nil
    ) {
        self.condition = condition
        self.property = property
        self.value = value
        self.isRequired = isRequired
    }

    private enum CodingKeys: String, CodingKey {
        case condition = "Condition"
        case property = "Property"
        case value = "Value"
        case isRequired = "IsRequired"
    }

    /// 宽松解码。
    ///
    /// - Parameter decoder: 解码器。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawCondition = container.embyString(forKey: .condition) ?? ""
        self.condition = rawCondition.isEmpty ? nil : ProfileConditionType(rawValue: rawCondition)
        let rawProperty = container.embyString(forKey: .property) ?? ""
        self.property = rawProperty.isEmpty ? nil : ProfileConditionValue(rawValue: rawProperty)
        self.value = container.embyString(forKey: .value)
        self.isRequired = container.embyBool(forKey: .isRequired)
    }

    /// 编码为 PascalCase。
    ///
    /// - Parameter encoder: 编码器。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(condition?.rawValue, forKey: .condition)
        try container.encodeIfPresent(property?.rawValue, forKey: .property)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encodeIfPresent(isRequired, forKey: .isRequired)
    }
}

// MARK: - 枚举

/// 媒体大类，对应 `DlnaProfileType`。
///
/// 取值来源（已核实）：<https://dev.emby.media/reference/RestAPI/MediaInfoService/postItemsByIdPlaybackinfo.html>
/// —— `Audio`、`Video`、`Photo`。
public struct DlnaProfileType: EmbyStringEnum {
    /// 原始字符串。
    public let rawValue: String

    /// 以原始字符串构造。
    ///
    /// - Parameter rawValue: 服务端返回值。
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// 音频。
    public static let audio = DlnaProfileType(rawValue: "Audio")
    /// 视频。
    public static let video = DlnaProfileType(rawValue: "Video")
    /// 图片。
    public static let photo = DlnaProfileType(rawValue: "Photo")
}

/// 转码上下文，对应 `EncodingContext`。
///
/// 取值来源（已核实）：同上 —— `Streaming`、`Static`。
public struct EncodingContext: EmbyStringEnum {
    /// 原始字符串。
    public let rawValue: String

    /// 以原始字符串构造。
    ///
    /// - Parameter rawValue: 服务端返回值。
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// 流式（边转边播）。
    public static let streaming = EncodingContext(rawValue: "Streaming")
    /// 静态（整段转完后提供）。
    public static let `static` = EncodingContext(rawValue: "Static")
}

/// 转码 seek 策略，对应 `TranscodeSeekInfo`。
///
/// 取值来源（已核实）：同上 —— `Auto`、`Bytes`。
public struct TranscodeSeekInfo: EmbyStringEnum {
    /// 原始字符串。
    public let rawValue: String

    /// 以原始字符串构造。
    ///
    /// - Parameter rawValue: 服务端返回值。
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// 自动。
    public static let auto = TranscodeSeekInfo(rawValue: "Auto")
    /// 按字节。
    public static let bytes = TranscodeSeekInfo(rawValue: "Bytes")
}

/// 编解码类型，对应 `CodecType`。
///
/// 取值来源（已核实）：同上 —— `Video`、`VideoAudio`、`Audio`。
public struct CodecType: EmbyStringEnum {
    /// 原始字符串。
    public let rawValue: String

    /// 以原始字符串构造。
    ///
    /// - Parameter rawValue: 服务端返回值。
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// 视频。
    public static let video = CodecType(rawValue: "Video")
    /// 视频中的音频轨。
    public static let videoAudio = CodecType(rawValue: "VideoAudio")
    /// 音频。
    public static let audio = CodecType(rawValue: "Audio")
}

/// 字幕交付方式，对应 `SubtitleDeliveryMethod`。
///
/// 取值来源（已核实）：同上 —— `Encode`、`Embed`、`External`、`Hls`、`VideoSideData`。
///
/// - Important: 图形字幕（`pgssub` / `dvdsub`）在 macOS 原生播放器上只能用 `Encode`（烧录），
///   文本字幕可以用 `External`（拿到字幕后自行渲染）。
public struct SubtitleDeliveryMethod: EmbyStringEnum {
    /// 原始字符串。
    public let rawValue: String

    /// 以原始字符串构造。
    ///
    /// - Parameter rawValue: 服务端返回值。
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// 烧录进画面。
    public static let encode = SubtitleDeliveryMethod(rawValue: "Encode")
    /// 封装进容器。
    public static let embed = SubtitleDeliveryMethod(rawValue: "Embed")
    /// 外挂（客户端自行拉取并渲染）。
    public static let external = SubtitleDeliveryMethod(rawValue: "External")
    /// 以 HLS 清单字幕交付。
    public static let hls = SubtitleDeliveryMethod(rawValue: "Hls")
    /// 视频 side data。
    public static let videoSideData = SubtitleDeliveryMethod(rawValue: "VideoSideData")
}

/// 条件比较方式，对应 `ProfileConditionType`。
///
/// 取值来源（已核实）：同上 —— `Equals`、`NotEquals`、`LessThanEqual`、
/// `GreaterThanEqual`、`EqualsAny`。
public struct ProfileConditionType: EmbyStringEnum {
    /// 原始字符串。
    public let rawValue: String

    /// 以原始字符串构造。
    ///
    /// - Parameter rawValue: 服务端返回值。
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// 等于。
    public static let equals = ProfileConditionType(rawValue: "Equals")
    /// 不等于。
    public static let notEquals = ProfileConditionType(rawValue: "NotEquals")
    /// 小于等于。
    public static let lessThanEqual = ProfileConditionType(rawValue: "LessThanEqual")
    /// 大于等于。
    public static let greaterThanEqual = ProfileConditionType(rawValue: "GreaterThanEqual")
    /// 等于其中任一（`Value` 为逗号分隔列表）。
    public static let equalsAny = ProfileConditionType(rawValue: "EqualsAny")
}

/// 条件属性，对应 `ProfileConditionValue`。
///
/// 取值来源（已核实）：同上 —— `AudioChannels`、`AudioBitrate`、`AudioProfile`、`Width`、
/// `Height`、`Has64BitOffsets`、`PacketLength`、`VideoBitDepth`、`VideoBitrate`、
/// `VideoFramerate`、`VideoLevel`、`VideoProfile`、`VideoTimestamp`、`IsAnamorphic`、
/// `RefFrames`、`NumAudioStreams`、`NumVideoStreams`、`IsSecondaryAudio`、`VideoCodecTag`、
/// `IsAvc`、`IsInterlaced`、`AudioSampleRate`、`AudioBitDepth`、`VideoRange`、
/// `VideoRotation`、`IsExternalAudio`。
public struct ProfileConditionValue: EmbyStringEnum {
    /// 原始字符串。
    public let rawValue: String

    /// 以原始字符串构造。
    ///
    /// - Parameter rawValue: 服务端返回值。
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// 音频声道数。
    public static let audioChannels = ProfileConditionValue(rawValue: "AudioChannels")
    /// 音频码率。
    public static let audioBitrate = ProfileConditionValue(rawValue: "AudioBitrate")
    /// 音频 profile。
    public static let audioProfile = ProfileConditionValue(rawValue: "AudioProfile")
    /// 宽度。
    public static let width = ProfileConditionValue(rawValue: "Width")
    /// 高度。
    public static let height = ProfileConditionValue(rawValue: "Height")
    /// 视频位深。
    public static let videoBitDepth = ProfileConditionValue(rawValue: "VideoBitDepth")
    /// 视频码率。
    public static let videoBitrate = ProfileConditionValue(rawValue: "VideoBitrate")
    /// 视频帧率。
    public static let videoFramerate = ProfileConditionValue(rawValue: "VideoFramerate")
    /// 视频 level。
    public static let videoLevel = ProfileConditionValue(rawValue: "VideoLevel")
    /// 视频 profile。
    public static let videoProfile = ProfileConditionValue(rawValue: "VideoProfile")
    /// 是否变形宽银幕。
    public static let isAnamorphic = ProfileConditionValue(rawValue: "IsAnamorphic")
    /// 参考帧数。
    public static let refFrames = ProfileConditionValue(rawValue: "RefFrames")
    /// 音频流数量。
    public static let numAudioStreams = ProfileConditionValue(rawValue: "NumAudioStreams")
    /// 视频流数量。
    public static let numVideoStreams = ProfileConditionValue(rawValue: "NumVideoStreams")
    /// 是否次级音轨。
    public static let isSecondaryAudio = ProfileConditionValue(rawValue: "IsSecondaryAudio")
    /// 是否 H.264。
    public static let isAvc = ProfileConditionValue(rawValue: "IsAvc")
    /// 是否隔行。
    public static let isInterlaced = ProfileConditionValue(rawValue: "IsInterlaced")
    /// 音频采样率。
    public static let audioSampleRate = ProfileConditionValue(rawValue: "AudioSampleRate")
    /// 音频位深。
    public static let audioBitDepth = ProfileConditionValue(rawValue: "AudioBitDepth")
    /// 视频动态范围（HDR / SDR）。
    public static let videoRange = ProfileConditionValue(rawValue: "VideoRange")
}

// MARK: - 现成的 macOS 能力描述

public extension DeviceProfile {
    /// Prism 在 macOS 上使用的默认能力描述。
    ///
    /// 字段名全部经官方 Reference 核实；**具体取值是按 macOS 播放能力给的建议值**，
    /// 需在真机上按解码实测微调（见 `docs/research/emby-api.md` §6.2.4）。
    ///
    /// 取舍说明：
    /// - `pgssub` / `dvdsub` 用 `Encode`（烧录）而不是 `External`：macOS 原生播放器
    ///   没有等价于 canvas 的字幕渲染能力，图形字幕必须烧进画面。
    /// - 文本字幕（`vtt` / `srt` / `ass` / `ssa` / `subrip`）用 `External`，
    ///   拿到字幕后由客户端自行渲染。
    /// - `MaxStreamingBitrate` 默认 120 Mbps 是局域网直连的宽松值；远程播放时应按
    ///   用户「质量设置」下调（如 8 / 4 / 2 Mbps）。
    ///
    /// - Parameter maxStreamingBitrate: 流媒体码率上限（bps）。
    /// - Returns: 可直接传给 ``PlaybackInfoEndpoint`` 的能力描述。
    static func prismMacOS(maxStreamingBitrate: Int64 = 120_000_000) -> DeviceProfile {
        DeviceProfile(
            name: "Prism macOS",
            maxStreamingBitrate: maxStreamingBitrate,
            maxStaticBitrate: 140_000_000,
            musicStreamingTranscodingBitrate: 384_000,
            directPlayProfiles: [
                DirectPlayProfile(
                    container: "mp4,m4v,mov",
                    audioCodec: "aac,ac3,eac3,alac,mp3,flac,opus",
                    videoCodec: "h264,hevc",
                    type: .video
                ),
                DirectPlayProfile(
                    container: "mkv",
                    audioCodec: "aac,ac3,eac3,flac,alac,mp3,opus,vorbis",
                    videoCodec: "h264,hevc",
                    type: .video
                ),
                DirectPlayProfile(container: "mp3", audioCodec: "mp3", type: .audio),
                DirectPlayProfile(container: "aac,m4a", audioCodec: "aac,alac", type: .audio),
                DirectPlayProfile(container: "flac", audioCodec: "flac", type: .audio),
                DirectPlayProfile(container: "ogg,oga,opus", audioCodec: "vorbis,opus", type: .audio),
                DirectPlayProfile(container: "wav", audioCodec: "pcm_s16le,pcm_s24le", type: .audio)
            ],
            transcodingProfiles: [
                TranscodingProfile(
                    container: "ts",
                    type: .video,
                    videoCodec: "h264",
                    audioCodec: "aac",
                    protocolName: "hls",
                    context: .streaming,
                    maxAudioChannels: "6",
                    minSegments: 1,
                    segmentLength: 6,
                    breakOnNonKeyFrames: false,
                    manifestSubtitles: "vtt"
                ),
                TranscodingProfile(
                    container: "mp4",
                    type: .video,
                    videoCodec: "h264",
                    audioCodec: "aac",
                    protocolName: "http",
                    context: .streaming,
                    maxAudioChannels: "6"
                ),
                TranscodingProfile(
                    container: "ts",
                    type: .audio,
                    audioCodec: "aac",
                    protocolName: "hls",
                    context: .streaming,
                    maxAudioChannels: "2",
                    minSegments: 1,
                    segmentLength: 6,
                    breakOnNonKeyFrames: false
                ),
                TranscodingProfile(
                    container: "mp3",
                    type: .audio,
                    audioCodec: "mp3",
                    protocolName: "http",
                    context: .streaming,
                    maxAudioChannels: "2"
                )
            ],
            codecProfiles: [
                CodecProfile(
                    type: .video,
                    conditions: [
                        ProfileCondition(
                            condition: .lessThanEqual,
                            property: .videoLevel,
                            value: "51",
                            isRequired: false
                        )
                    ],
                    codec: "h264"
                ),
                CodecProfile(
                    type: .videoAudio,
                    conditions: [
                        ProfileCondition(
                            condition: .lessThanEqual,
                            property: .audioChannels,
                            value: "6",
                            isRequired: false
                        )
                    ]
                ),
                CodecProfile(
                    type: .video,
                    conditions: [
                        ProfileCondition(
                            condition: .notEquals,
                            property: .isAnamorphic,
                            value: "true",
                            isRequired: false
                        )
                    ]
                )
            ],
            responseProfiles: [
                ResponseProfile(container: "m4v", videoCodec: nil, type: .video, mimeType: "video/mp4")
            ],
            subtitleProfiles: [
                SubtitleProfile(format: "vtt", method: .external),
                SubtitleProfile(format: "srt", method: .external),
                SubtitleProfile(format: "ass", method: .external),
                SubtitleProfile(format: "ssa", method: .external),
                SubtitleProfile(format: "subrip", method: .external),
                SubtitleProfile(format: "pgssub", method: .encode),
                SubtitleProfile(format: "dvdsub", method: .encode)
            ]
        )
    }
}
