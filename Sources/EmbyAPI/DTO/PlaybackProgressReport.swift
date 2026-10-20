import Foundation
import PrismCore

/// 播放进度上报的请求体，对应 Emby 的 `PlaybackProgressInfo`。
///
/// 字段来源（已核实）：<https://dev.emby.media/reference/RestAPI/PlaystateService/postSessionsPlayingProgress.html>
/// 的 Definitions 段（30 个字段）。`POST /Sessions/Playing` 的 `PlaybackStartInfo`
/// 与它**字段完全相同**（官方 Reference 两页逐项一致），因此本类型同时用于
/// ``PlayingStartEndpoint`` 与 ``PlayingProgressEndpoint``。
///
/// ## 不要发 `QueueableMediaTypes`
///
/// 官方 `Playback-Check-ins` 文档列了它，但 4.x 的 `PlaybackStartInfo` / `PlaybackProgressInfo`
/// schema 里**没有**该字段（3.x 时代的遗留）。本类型故意不提供它。
/// 见 <https://dev.emby.media/doc/restapi/Playback-Check-ins.html>。
///
/// ## 用法
///
/// ```swift
/// var report = PlaybackProgressReport(
///     itemId: item.id,
///     playSessionId: info.playSessionId,
///     mediaSourceId: source.id,
///     positionTicks: .zero
/// )
/// report.playMethod = .directPlay
/// report.eventName = .timeUpdate
/// report.isPaused = false
/// try await client.send(PlayingProgressEndpoint(report: report))
/// ```
///
/// - Important: `PositionTicks` 单位是 .NET tick（1 tick = 100 ns，10,000,000 ticks = 1 秒）。
///   见 ``PrismCore/Ticks``。
public struct PlaybackProgressReport: Sendable, Codable, Hashable {
    /// 条目 id（库内条目用这个，与 ``item`` 二选一）。
    public var itemId: String

    /// 播放会话 id（`PlaybackInfo` 返回的 `PlaySessionId`，必须原样透传）。
    public var playSessionId: String?

    /// 媒体源 id。
    public var mediaSourceId: String?

    /// 当前位置。
    public var positionTicks: Ticks?

    /// 上报原因。`Progress` 场景必填（`TimeUpdate` / `Pause` / `Unpause`…）。
    public var eventName: ProgressEvent?

    /// 播放方式（`DirectPlay` / `DirectStream` / `Transcode`）。
    public var playMethod: PlayMethod?

    /// 是否暂停。
    public var isPaused: Bool?

    /// 是否静音。
    public var isMuted: Bool?

    /// 音量（0–100）。
    public var volumeLevel: Int?

    /// 是否可 seek。
    public var canSeek: Bool?

    /// 当前音轨序号。
    public var audioStreamIndex: Int?

    /// 当前字幕序号（`-1` 表示关闭）。
    public var subtitleStreamIndex: Int?

    /// 条目总时长。
    public var runTimeTicks: Ticks?

    /// 起播时刻（ticks）。
    public var playbackStartTimeTicks: Ticks?

    /// 倍速。
    public var playbackRate: Double?

    /// 字幕延迟。
    public var subtitleOffset: Int?

    /// 循环模式。
    public var repeatMode: RepeatMode?

    /// 是否随机播放。
    public var shuffle: Bool?

    /// 睡眠定时模式。
    public var sleepTimerMode: SleepTimerMode?

    /// 睡眠定时结束时间。
    public var sleepTimerEndTime: Date?

    /// 播放队列当前位置。
    public var playlistIndex: Int?

    /// 队列总长。
    public var playlistLength: Int?

    /// 当前队列项 id。
    public var playlistItemId: String?

    /// 队列全部项 id。
    public var playlistItemIds: [String]?

    /// 队列内容。
    public var nowPlayingQueue: [QueueItem]?

    /// 会话 id。
    public var sessionId: String?

    /// 直播流 id。
    public var liveStreamId: String?

    /// 画面亮度调整。
    public var brightness: Int?

    /// 画面宽高比调整。
    public var aspectRatio: String?

    /// 库外内容才用：条目描述对象。库内条目只传 ``itemId``，不要传它。
    ///
    /// 【待验证】Reference 把该字段标为 `BaseItemDto[]`（数组），实际应为单个对象；
    /// 编码时按单个对象写出。
    public var item: MediaItem?

    /// 以最小必要字段创建上报体。
    ///
    /// - Parameters:
    ///   - itemId: 条目 id。
    ///   - playSessionId: 播放会话 id。
    ///   - mediaSourceId: 媒体源 id。
    ///   - positionTicks: 当前位置。
    public init(
        itemId: String,
        playSessionId: String? = nil,
        mediaSourceId: String? = nil,
        positionTicks: Ticks? = nil
    ) {
        self.itemId = itemId
        self.playSessionId = playSessionId
        self.mediaSourceId = mediaSourceId
        self.positionTicks = positionTicks
    }

    private enum CodingKeys: String, CodingKey {
        case itemId = "ItemId"
        case playSessionId = "PlaySessionId"
        case mediaSourceId = "MediaSourceId"
        case positionTicks = "PositionTicks"
        case eventName = "EventName"
        case playMethod = "PlayMethod"
        case isPaused = "IsPaused"
        case isMuted = "IsMuted"
        case volumeLevel = "VolumeLevel"
        case canSeek = "CanSeek"
        case audioStreamIndex = "AudioStreamIndex"
        case subtitleStreamIndex = "SubtitleStreamIndex"
        case runTimeTicks = "RunTimeTicks"
        case playbackStartTimeTicks = "PlaybackStartTimeTicks"
        case playbackRate = "PlaybackRate"
        case subtitleOffset = "SubtitleOffset"
        case repeatMode = "RepeatMode"
        case shuffle = "Shuffle"
        case sleepTimerMode = "SleepTimerMode"
        case sleepTimerEndTime = "SleepTimerEndTime"
        case playlistIndex = "PlaylistIndex"
        case playlistLength = "PlaylistLength"
        case playlistItemId = "PlaylistItemId"
        case playlistItemIds = "PlaylistItemIds"
        case nowPlayingQueue = "NowPlayingQueue"
        case sessionId = "SessionId"
        case liveStreamId = "LiveStreamId"
        case brightness = "Brightness"
        case aspectRatio = "AspectRatio"
        case item = "Item"
    }

    /// 宽松解码：所有可选字段缺失都退化为 `nil`。
    ///
    /// - Parameter decoder: 解码器。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.itemId = container.embyString(forKey: .itemId) ?? ""
        self.playSessionId = container.embyString(forKey: .playSessionId)
        self.mediaSourceId = container.embyString(forKey: .mediaSourceId)
        self.positionTicks = container.embyTicks(forKey: .positionTicks)
        let rawEvent = container.embyString(forKey: .eventName) ?? ""
        self.eventName = rawEvent.isEmpty ? nil : ProgressEvent(rawValue: rawEvent)
        let rawMethod = container.embyString(forKey: .playMethod) ?? ""
        self.playMethod = rawMethod.isEmpty ? nil : PlayMethod(rawValue: rawMethod)
        self.isPaused = container.embyBool(forKey: .isPaused)
        self.isMuted = container.embyBool(forKey: .isMuted)
        self.volumeLevel = container.embyInt(forKey: .volumeLevel)
        self.canSeek = container.embyBool(forKey: .canSeek)
        self.audioStreamIndex = container.embyInt(forKey: .audioStreamIndex)
        self.subtitleStreamIndex = container.embyInt(forKey: .subtitleStreamIndex)
        self.runTimeTicks = container.embyTicks(forKey: .runTimeTicks)
        self.playbackStartTimeTicks = container.embyTicks(forKey: .playbackStartTimeTicks)
        self.playbackRate = container.embyDouble(forKey: .playbackRate)
        self.subtitleOffset = container.embyInt(forKey: .subtitleOffset)
        let rawRepeat = container.embyString(forKey: .repeatMode) ?? ""
        self.repeatMode = rawRepeat.isEmpty ? nil : RepeatMode(rawValue: rawRepeat)
        self.shuffle = container.embyBool(forKey: .shuffle)
        let rawSleep = container.embyString(forKey: .sleepTimerMode) ?? ""
        self.sleepTimerMode = rawSleep.isEmpty ? nil : SleepTimerMode(rawValue: rawSleep)
        self.sleepTimerEndTime = container.decodeEmbyDateIfPresent(forKey: .sleepTimerEndTime)
        self.playlistIndex = container.embyInt(forKey: .playlistIndex)
        self.playlistLength = container.embyInt(forKey: .playlistLength)
        self.playlistItemId = container.embyString(forKey: .playlistItemId)
        self.playlistItemIds = (try? container.decodeIfPresent([String].self, forKey: .playlistItemIds)) ?? nil
        self.nowPlayingQueue = (try? container.decodeIfPresent([QueueItem].self, forKey: .nowPlayingQueue)) ?? nil
        self.sessionId = container.embyString(forKey: .sessionId)
        self.liveStreamId = container.embyString(forKey: .liveStreamId)
        self.brightness = container.embyInt(forKey: .brightness)
        self.aspectRatio = container.embyString(forKey: .aspectRatio)
        let itemWrapper = try? container.decodeIfPresent(OneOrMany<MediaItem>.self, forKey: .item)
        self.item = itemWrapper?.value
    }

    /// 按 Emby 的 PascalCase 字段名编码；`nil` 字段不写入。
    ///
    /// - Parameter encoder: 编码器。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(itemId, forKey: .itemId)
        try container.encodeIfPresent(playSessionId, forKey: .playSessionId)
        try container.encodeIfPresent(mediaSourceId, forKey: .mediaSourceId)
        try container.encodeIfPresent(positionTicks, forKey: .positionTicks)
        try container.encodeIfPresent(eventName?.rawValue, forKey: .eventName)
        try container.encodeIfPresent(playMethod?.rawValue, forKey: .playMethod)
        try container.encodeIfPresent(isPaused, forKey: .isPaused)
        try container.encodeIfPresent(isMuted, forKey: .isMuted)
        try container.encodeIfPresent(volumeLevel, forKey: .volumeLevel)
        try container.encodeIfPresent(canSeek, forKey: .canSeek)
        try container.encodeIfPresent(audioStreamIndex, forKey: .audioStreamIndex)
        try container.encodeIfPresent(subtitleStreamIndex, forKey: .subtitleStreamIndex)
        try container.encodeIfPresent(runTimeTicks, forKey: .runTimeTicks)
        try container.encodeIfPresent(playbackStartTimeTicks, forKey: .playbackStartTimeTicks)
        try container.encodeIfPresent(playbackRate, forKey: .playbackRate)
        try container.encodeIfPresent(subtitleOffset, forKey: .subtitleOffset)
        try container.encodeIfPresent(repeatMode?.rawValue, forKey: .repeatMode)
        try container.encodeIfPresent(shuffle, forKey: .shuffle)
        try container.encodeIfPresent(sleepTimerMode?.rawValue, forKey: .sleepTimerMode)
        try container.encodeEmbyDateIfPresent(sleepTimerEndTime, forKey: .sleepTimerEndTime)
        try container.encodeIfPresent(playlistIndex, forKey: .playlistIndex)
        try container.encodeIfPresent(playlistLength, forKey: .playlistLength)
        try container.encodeIfPresent(playlistItemId, forKey: .playlistItemId)
        try container.encodeIfPresent(playlistItemIds, forKey: .playlistItemIds)
        try container.encodeIfPresent(nowPlayingQueue, forKey: .nowPlayingQueue)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(liveStreamId, forKey: .liveStreamId)
        try container.encodeIfPresent(brightness, forKey: .brightness)
        try container.encodeIfPresent(aspectRatio, forKey: .aspectRatio)
        try container.encodeIfPresent(item, forKey: .item)
    }
}

/// 停止播放上报的请求体，对应 Emby 的 `PlaybackStopInfo`。
///
/// 字段来源（已核实）：<https://dev.emby.media/reference/RestAPI/PlaystateService/postSessionsPlayingStopped.html>
/// 的 Definitions 段（**14 个字段**）：`ItemId`、`MediaSourceId`、`PlaySessionId`、
/// `PositionTicks`、`Failed`、`IsAutomated`、`NextMediaType`、`LiveStreamId`、
/// `PlaylistIndex`、`PlaylistLength`、`PlaylistItemId`、`NowPlayingQueue`、`SessionId`、`Item`。
///
/// - Important: 官方 `Playback-Check-ins` 文档声称停止请求「与开始请求内容完全相同」，
///   但 schema 只有这 14 个字段（**没有** `PlayMethod`、`IsPaused`、`VolumeLevel`、
///   `AudioStreamIndex` 等）。本类型按 schema 实现。
///   写进度真正必需的是 `ItemId` + `MediaSourceId` + `PlaySessionId` + `PositionTicks`。
public struct PlaybackStopReport: Sendable, Codable, Hashable {
    /// 条目 id。
    public var itemId: String
    /// 媒体源 id。
    public var mediaSourceId: String?
    /// 播放会话 id。
    public var playSessionId: String?
    /// 停止位置（写进度就靠它）。
    public var positionTicks: Ticks?
    /// 是否因失败而停止。
    public var failed: Bool?
    /// 是否由系统自动触发（非用户操作）。
    public var isAutomated: Bool?
    /// 下一个媒体类型。
    public var nextMediaType: String?
    /// 直播流 id。
    public var liveStreamId: String?
    /// 队列位置。
    public var playlistIndex: Int?
    /// 队列长度。
    public var playlistLength: Int?
    /// 队列项 id。
    public var playlistItemId: String?
    /// 队列内容。
    public var nowPlayingQueue: [QueueItem]?
    /// 会话 id。
    public var sessionId: String?
    /// 库外内容才用（库内条目只传 ``itemId``）。
    public var item: MediaItem?

    /// 以最小必要字段创建停止上报体。
    ///
    /// - Parameters:
    ///   - itemId: 条目 id。
    ///   - playSessionId: 播放会话 id。
    ///   - mediaSourceId: 媒体源 id。
    ///   - positionTicks: 停止位置。
    public init(
        itemId: String,
        playSessionId: String? = nil,
        mediaSourceId: String? = nil,
        positionTicks: Ticks? = nil
    ) {
        self.itemId = itemId
        self.playSessionId = playSessionId
        self.mediaSourceId = mediaSourceId
        self.positionTicks = positionTicks
    }

    private enum CodingKeys: String, CodingKey {
        case itemId = "ItemId"
        case mediaSourceId = "MediaSourceId"
        case playSessionId = "PlaySessionId"
        case positionTicks = "PositionTicks"
        case failed = "Failed"
        case isAutomated = "IsAutomated"
        case nextMediaType = "NextMediaType"
        case liveStreamId = "LiveStreamId"
        case playlistIndex = "PlaylistIndex"
        case playlistLength = "PlaylistLength"
        case playlistItemId = "PlaylistItemId"
        case nowPlayingQueue = "NowPlayingQueue"
        case sessionId = "SessionId"
        case item = "Item"
    }

    /// 宽松解码。
    ///
    /// - Parameter decoder: 解码器。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.itemId = container.embyString(forKey: .itemId) ?? ""
        self.mediaSourceId = container.embyString(forKey: .mediaSourceId)
        self.playSessionId = container.embyString(forKey: .playSessionId)
        self.positionTicks = container.embyTicks(forKey: .positionTicks)
        self.failed = container.embyBool(forKey: .failed)
        self.isAutomated = container.embyBool(forKey: .isAutomated)
        self.nextMediaType = container.embyString(forKey: .nextMediaType)
        self.liveStreamId = container.embyString(forKey: .liveStreamId)
        self.playlistIndex = container.embyInt(forKey: .playlistIndex)
        self.playlistLength = container.embyInt(forKey: .playlistLength)
        self.playlistItemId = container.embyString(forKey: .playlistItemId)
        self.nowPlayingQueue = (try? container.decodeIfPresent([QueueItem].self, forKey: .nowPlayingQueue)) ?? nil
        self.sessionId = container.embyString(forKey: .sessionId)
        let itemWrapper = try? container.decodeIfPresent(OneOrMany<MediaItem>.self, forKey: .item)
        self.item = itemWrapper?.value
    }

    /// 按 Emby 的 PascalCase 字段名编码；`nil` 字段不写入。
    ///
    /// - Parameter encoder: 编码器。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(itemId, forKey: .itemId)
        try container.encodeIfPresent(mediaSourceId, forKey: .mediaSourceId)
        try container.encodeIfPresent(playSessionId, forKey: .playSessionId)
        try container.encodeIfPresent(positionTicks, forKey: .positionTicks)
        try container.encodeIfPresent(failed, forKey: .failed)
        try container.encodeIfPresent(isAutomated, forKey: .isAutomated)
        try container.encodeIfPresent(nextMediaType, forKey: .nextMediaType)
        try container.encodeIfPresent(liveStreamId, forKey: .liveStreamId)
        try container.encodeIfPresent(playlistIndex, forKey: .playlistIndex)
        try container.encodeIfPresent(playlistLength, forKey: .playlistLength)
        try container.encodeIfPresent(playlistItemId, forKey: .playlistItemId)
        try container.encodeIfPresent(nowPlayingQueue, forKey: .nowPlayingQueue)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(item, forKey: .item)
    }
}

/// 播放队列项，对应 `QueueItem`。
///
/// 字段来源（已核实）：<https://dev.emby.media/reference/RestAPI/PlaystateService/postSessionsPlayingProgress.html>
/// 的 Definitions 段 —— `Id`（int64）、`PlaylistItemId`。
public struct QueueItem: Sendable, Codable, Hashable {
    /// 队列序号。
    public let id: Int64
    /// 队列项 id。
    public let playlistItemId: String?

    /// 完整初始化。
    ///
    /// - Parameters:
    ///   - id: 队列序号。
    ///   - playlistItemId: 队列项 id。
    public init(id: Int64, playlistItemId: String? = nil) {
        self.id = id
        self.playlistItemId = playlistItemId
    }

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case playlistItemId = "PlaylistItemId"
    }

    /// 宽松解码。
    ///
    /// - Parameter decoder: 解码器。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = container.embyInt64(forKey: .id) ?? 0
        self.playlistItemId = container.embyString(forKey: .playlistItemId)
    }

    /// 编码为 PascalCase。
    ///
    /// - Parameter encoder: 编码器。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(playlistItemId, forKey: .playlistItemId)
    }
}

// MARK: - 枚举

/// 播放方式，对应 `PlayMethod`。
///
/// 取值来源（已核实）：<https://dev.emby.media/reference/RestAPI/PlaystateService/postSessionsPlaying.html>
/// —— `Transcode`、`DirectStream`、`DirectPlay`。
public struct PlayMethod: EmbyStringEnum {
    /// 原始字符串。
    public let rawValue: String

    /// 以原始字符串构造。
    ///
    /// - Parameter rawValue: 服务端返回值。
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// 服务器转码。
    public static let transcode = PlayMethod(rawValue: "Transcode")
    /// 原样拉流（只重封装）。
    public static let directStream = PlayMethod(rawValue: "DirectStream")
    /// 直连播放。
    public static let directPlay = PlayMethod(rawValue: "DirectPlay")
}

/// 进度上报原因，对应 `ProgressEvent`。
///
/// 取值来源（已核实）：<https://dev.emby.media/reference/RestAPI/PlaystateService/postSessionsPlayingProgress.html>
/// 的 Definitions 段（16 个值）。
///
/// - Note: 暂停 / 恢复**不是**独立端点，而是发 Progress 且
///   `EventName=Pause|Unpause`、`IsPaused=true|false`。
public struct ProgressEvent: EmbyStringEnum {
    /// 原始字符串。
    public let rawValue: String

    /// 以原始字符串构造。
    ///
    /// - Parameter rawValue: 服务端返回值。
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// 定时上报（每 10 秒一次）。
    public static let timeUpdate = ProgressEvent(rawValue: "TimeUpdate")
    /// 暂停。
    public static let pause = ProgressEvent(rawValue: "Pause")
    /// 恢复播放。
    public static let unpause = ProgressEvent(rawValue: "Unpause")
    /// 音量变化。
    public static let volumeChange = ProgressEvent(rawValue: "VolumeChange")
    /// 循环模式变化。
    public static let repeatModeChange = ProgressEvent(rawValue: "RepeatModeChange")
    /// 切换音轨。
    public static let audioTrackChange = ProgressEvent(rawValue: "AudioTrackChange")
    /// 切换字幕。
    public static let subtitleTrackChange = ProgressEvent(rawValue: "SubtitleTrackChange")
    /// 队列移动。
    public static let playlistItemMove = ProgressEvent(rawValue: "PlaylistItemMove")
    /// 队列移除。
    public static let playlistItemRemove = ProgressEvent(rawValue: "PlaylistItemRemove")
    /// 队列新增。
    public static let playlistItemAdd = ProgressEvent(rawValue: "PlaylistItemAdd")
    /// 画质变化。
    public static let qualityChange = ProgressEvent(rawValue: "QualityChange")
    /// 状态变化。
    public static let stateChange = ProgressEvent(rawValue: "StateChange")
    /// 字幕延迟变化。
    public static let subtitleOffsetChange = ProgressEvent(rawValue: "SubtitleOffsetChange")
    /// 倍速变化。
    public static let playbackRateChange = ProgressEvent(rawValue: "PlaybackRateChange")
    /// 随机播放变化。
    public static let shuffleChange = ProgressEvent(rawValue: "ShuffleChange")
    /// 睡眠定时变化。
    public static let sleepTimerChange = ProgressEvent(rawValue: "SleepTimerChange")
}

/// 循环模式，对应 `RepeatMode`。
///
/// 取值来源（已核实）：同上 —— `RepeatNone`、`RepeatAll`、`RepeatOne`。
public struct RepeatMode: EmbyStringEnum {
    /// 原始字符串。
    public let rawValue: String

    /// 以原始字符串构造。
    ///
    /// - Parameter rawValue: 服务端返回值。
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// 不循环。
    public static let none = RepeatMode(rawValue: "RepeatNone")
    /// 列表循环。
    public static let all = RepeatMode(rawValue: "RepeatAll")
    /// 单曲循环。
    public static let one = RepeatMode(rawValue: "RepeatOne")
}

/// 睡眠定时模式，对应 `SleepTimerMode`。
///
/// 取值来源（已核实）：同上 —— `None`、`AfterItem`、`AtTime`。
public struct SleepTimerMode: EmbyStringEnum {
    /// 原始字符串。
    public let rawValue: String

    /// 以原始字符串构造。
    ///
    /// - Parameter rawValue: 服务端返回值。
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// 未启用。
    public static let none = SleepTimerMode(rawValue: "None")
    /// 当前条目结束后。
    public static let afterItem = SleepTimerMode(rawValue: "AfterItem")
    /// 指定时刻。
    public static let atTime = SleepTimerMode(rawValue: "AtTime")
}
