import Foundation
import PrismCore

/// 播放协商请求体，对应 Emby 的 `PlaybackInfoRequest`。
///
/// 字段来源（已核实，**以 Reference 页为准的 19 个字段**）：
/// <https://dev.emby.media/reference/RestAPI/MediaInfoService/postItemsByIdPlaybackinfo.html>
/// —— `Id`、`UserId`、`MaxStreamingBitrate`、`StartTimeTicks`、`AudioStreamIndex`、
/// `SubtitleStreamIndex`、`MaxAudioChannels`、`MediaSourceId`、`LiveStreamId`、`DeviceProfile`、
/// `EnableDirectPlay`、`EnableDirectStream`、`EnableTranscoding`、
/// `AllowInterlacedVideoStreamCopy`、`AllowVideoStreamCopy`、`AllowAudioStreamCopy`、
/// `IsPlayback`、`AutoOpenLiveStream`、`CurrentPlaySessionId`。
///
/// - Note: 官方 OpenAPI 快照（4.1.1.0）只有 18 个字段，缺 `CurrentPlaySessionId` 与
///   `AllowInterlacedVideoStreamCopy`，多一个 `DirectPlayProtocols`。本类型按 Reference 实现。
///
/// ## ⚠️ `DeviceProfile` 的数组标注
///
/// Reference 把 `DeviceProfile` 标成 `DeviceProfile[]`（数组），但真实客户端（jellyfin-web、
/// Emby Web）一律按**单个对象**发送，Emby 也按单对象读取。本类型**编码为单个对象**；
/// 解码时用 ``OneOrMany`` 同时容忍两种形态。
/// 【待验证】在真实 4.8 / 4.9 服务器上分别用对象与数组各发一次，确认都能正常协商。
public struct PlaybackInfoRequest: Sendable, Codable, Hashable {
    /// 条目 id。路径里已有 `{Id}`，body 里再给一份（官方 schema 有该字段）。
    public var id: String?

    /// 用户 id。
    public var userId: String?

    /// 流媒体码率上限（bps）。
    public var maxStreamingBitrate: Int64?

    /// 起播位置。
    public var startTimeTicks: Ticks?

    /// 指定音轨序号。
    public var audioStreamIndex: Int?

    /// 指定字幕序号（`-1` 表示关闭）。
    public var subtitleStreamIndex: Int?

    /// 最大声道数（`2` = 立体声）。
    public var maxAudioChannels: Int?

    /// 指定媒体源（多版本时）。
    public var mediaSourceId: String?

    /// 直播流 id。
    public var liveStreamId: String?

    /// 客户端能力描述 —— **协商成败的关键**。
    public var deviceProfile: DeviceProfile?

    /// 允许直连播放。
    public var enableDirectPlay: Bool?

    /// 允许直封。
    public var enableDirectStream: Bool?

    /// 允许转码。
    public var enableTranscoding: Bool?

    /// 允许隔行视频流拷贝。
    public var allowInterlacedVideoStreamCopy: Bool?

    /// 转码时允许视频流拷贝。
    public var allowVideoStreamCopy: Bool?

    /// 转码时允许音频流拷贝。
    public var allowAudioStreamCopy: Bool?

    /// 是否真实播放（`true` 时服务器会计入会话）。
    public var isPlayback: Bool?

    /// 自动打开直播流。
    public var autoOpenLiveStream: Bool?

    /// 当前播放会话 id（换流 / 纠错时传上一次的）。
    public var currentPlaySessionId: String?

    /// 以最常用的字段创建请求体。
    ///
    /// 默认值按「局域网播放一个库内条目」设定：直连 / 直封 / 转码全开，`IsPlayback = true`。
    ///
    /// - Parameters:
    ///   - itemId: 条目 id。
    ///   - userId: 用户 id。
    ///   - deviceProfile: 客户端能力描述。
    ///   - maxStreamingBitrate: 码率上限；`nil` 时用 `deviceProfile` 里的值。
    ///   - startTimeTicks: 起播位置。
    public init(
        itemId: String,
        userId: String,
        deviceProfile: DeviceProfile? = nil,
        maxStreamingBitrate: Int64? = nil,
        startTimeTicks: Ticks? = nil
    ) {
        self.id = itemId
        self.userId = userId
        self.deviceProfile = deviceProfile
        self.maxStreamingBitrate = maxStreamingBitrate ?? deviceProfile?.maxStreamingBitrate
        self.startTimeTicks = startTimeTicks
        self.enableDirectPlay = true
        self.enableDirectStream = true
        self.enableTranscoding = true
        self.isPlayback = true
    }

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case userId = "UserId"
        case maxStreamingBitrate = "MaxStreamingBitrate"
        case startTimeTicks = "StartTimeTicks"
        case audioStreamIndex = "AudioStreamIndex"
        case subtitleStreamIndex = "SubtitleStreamIndex"
        case maxAudioChannels = "MaxAudioChannels"
        case mediaSourceId = "MediaSourceId"
        case liveStreamId = "LiveStreamId"
        case deviceProfile = "DeviceProfile"
        case enableDirectPlay = "EnableDirectPlay"
        case enableDirectStream = "EnableDirectStream"
        case enableTranscoding = "EnableTranscoding"
        case allowInterlacedVideoStreamCopy = "AllowInterlacedVideoStreamCopy"
        case allowVideoStreamCopy = "AllowVideoStreamCopy"
        case allowAudioStreamCopy = "AllowAudioStreamCopy"
        case isPlayback = "IsPlayback"
        case autoOpenLiveStream = "AutoOpenLiveStream"
        case currentPlaySessionId = "CurrentPlaySessionId"
    }

    /// 宽松解码：`DeviceProfile` 兼容对象与数组两种形态。
    ///
    /// - Parameter decoder: 解码器。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = container.embyString(forKey: .id)
        self.userId = container.embyString(forKey: .userId)
        self.maxStreamingBitrate = container.embyInt64(forKey: .maxStreamingBitrate)
        self.startTimeTicks = container.embyTicks(forKey: .startTimeTicks)
        self.audioStreamIndex = container.embyInt(forKey: .audioStreamIndex)
        self.subtitleStreamIndex = container.embyInt(forKey: .subtitleStreamIndex)
        self.maxAudioChannels = container.embyInt(forKey: .maxAudioChannels)
        self.mediaSourceId = container.embyString(forKey: .mediaSourceId)
        self.liveStreamId = container.embyString(forKey: .liveStreamId)
        let profile = try? container.decodeIfPresent(OneOrMany<DeviceProfile>.self, forKey: .deviceProfile)
        self.deviceProfile = profile?.value
        self.enableDirectPlay = container.embyBool(forKey: .enableDirectPlay)
        self.enableDirectStream = container.embyBool(forKey: .enableDirectStream)
        self.enableTranscoding = container.embyBool(forKey: .enableTranscoding)
        self.allowInterlacedVideoStreamCopy = container.embyBool(forKey: .allowInterlacedVideoStreamCopy)
        self.allowVideoStreamCopy = container.embyBool(forKey: .allowVideoStreamCopy)
        self.allowAudioStreamCopy = container.embyBool(forKey: .allowAudioStreamCopy)
        self.isPlayback = container.embyBool(forKey: .isPlayback)
        self.autoOpenLiveStream = container.embyBool(forKey: .autoOpenLiveStream)
        self.currentPlaySessionId = container.embyString(forKey: .currentPlaySessionId)
    }

    /// 按 Emby 的 PascalCase 字段名编码；`nil` 字段不写入（`DeviceProfile` 写为单个对象）。
    ///
    /// - Parameter encoder: 编码器。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(userId, forKey: .userId)
        try container.encodeIfPresent(maxStreamingBitrate, forKey: .maxStreamingBitrate)
        try container.encodeIfPresent(startTimeTicks, forKey: .startTimeTicks)
        try container.encodeIfPresent(audioStreamIndex, forKey: .audioStreamIndex)
        try container.encodeIfPresent(subtitleStreamIndex, forKey: .subtitleStreamIndex)
        try container.encodeIfPresent(maxAudioChannels, forKey: .maxAudioChannels)
        try container.encodeIfPresent(mediaSourceId, forKey: .mediaSourceId)
        try container.encodeIfPresent(liveStreamId, forKey: .liveStreamId)
        try container.encodeIfPresent(deviceProfile, forKey: .deviceProfile)
        try container.encodeIfPresent(enableDirectPlay, forKey: .enableDirectPlay)
        try container.encodeIfPresent(enableDirectStream, forKey: .enableDirectStream)
        try container.encodeIfPresent(enableTranscoding, forKey: .enableTranscoding)
        try container.encodeIfPresent(allowInterlacedVideoStreamCopy, forKey: .allowInterlacedVideoStreamCopy)
        try container.encodeIfPresent(allowVideoStreamCopy, forKey: .allowVideoStreamCopy)
        try container.encodeIfPresent(allowAudioStreamCopy, forKey: .allowAudioStreamCopy)
        try container.encodeIfPresent(isPlayback, forKey: .isPlayback)
        try container.encodeIfPresent(autoOpenLiveStream, forKey: .autoOpenLiveStream)
        try container.encodeIfPresent(currentPlaySessionId, forKey: .currentPlaySessionId)
    }
}
