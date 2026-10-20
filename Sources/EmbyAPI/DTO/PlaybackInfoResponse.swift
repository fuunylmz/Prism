import Foundation
import PrismCore

/// 播放协商结果，对应 Emby 的 `PlaybackInfoResponse`。
///
/// 字段来源（已核实）：<https://dev.emby.media/reference/RestAPI/MediaInfoService/postItemsByIdPlaybackinfo.html>
/// 的 Definitions 段 —— `MediaSources: MediaSourceInfo[]`、`PlaySessionId: string`、
/// `ErrorCode: PlaybackErrorCode`。
///
/// - Important: `PlaySessionId` 由服务器每次生成一个新值，**必须**原样带到
///   `/Sessions/Playing`、`/Sessions/Playing/Progress`、`/Sessions/Playing/Stopped`，
///   而且转码 URL 里已经内嵌了它 —— 不要改写、不要缓存复用。
///
/// ## ⚠️ `DirectStreamUrl` 存在 ≠ 能直封（最容易踩的坑）
///
/// 抓包实证：**需要转码时 Emby 照样返回 `DirectStreamUrl`**，其值常常与 `TranscodingUrl`
/// 完全相同（都带 `TranscodeReasons=`）。因此**判定直封能力只能看
/// `MediaSource.SupportsDirectStream` 这个布尔值**，不能看 `DirectStreamUrl` 是否存在。
///
/// 正确的判定顺序：
/// 1. `SupportsDirectPlay == true` 且本地解码器支持该容器/编码 → DirectPlay
/// 2. 否则 `SupportsDirectStream == true` → DirectStream（用 `DirectStreamUrl`）
/// 3. 否则 → Transcode（用 `TranscodingUrl`）
///
/// 来源：<https://emby.media/community/topic/92430-session-playstate-mediasourceid-session-fullplayingitemgetmediasources>
/// （真实会话 JSON 里 `SupportsDirectStream: false` 却仍返回了 `DirectStreamUrl`）。
public struct PlaybackInfoResponse: Sendable, Codable, Hashable {
    /// 可用的媒体源（已按请求里的 `DeviceProfile` 计算过）。
    public let mediaSources: [MediaSource]

    /// 本次播放会话 id。
    public let playSessionId: String?

    /// 失败原因；成功时为 `nil`。
    public let errorCode: PlaybackErrorCode?

    /// 完整初始化。
    ///
    /// - Parameters:
    ///   - mediaSources: 可用媒体源。
    ///   - playSessionId: 播放会话 id。
    ///   - errorCode: 失败原因。
    public init(
        mediaSources: [MediaSource] = [],
        playSessionId: String? = nil,
        errorCode: PlaybackErrorCode? = nil
    ) {
        self.mediaSources = mediaSources
        self.playSessionId = playSessionId
        self.errorCode = errorCode
    }

    /// 第一个媒体源（单版本场景直接用它）。
    public var primarySource: MediaSource? {
        mediaSources.first
    }

    /// 协商是否成功（有媒体源且没有错误码）。
    public var isPlayable: Bool {
        errorCode == nil && !mediaSources.isEmpty
    }

    /// 是否被服务器限流（`ErrorCode == RateLimitExceeded`）。
    public var isRateLimited: Bool {
        errorCode == .rateLimitExceeded
    }

    private enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources"
        case playSessionId = "PlaySessionId"
        case errorCode = "ErrorCode"
    }

    /// 宽松解码：`MediaSources` 缺失返回空数组，坏元素只丢自己。
    ///
    /// - Parameter decoder: 解码器。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mediaSources = container.embyArray(MediaSource.self, forKey: .mediaSources)
        self.playSessionId = container.embyString(forKey: .playSessionId)
        let rawError = container.embyString(forKey: .errorCode) ?? ""
        self.errorCode = rawError.isEmpty ? nil : PlaybackErrorCode(rawValue: rawError)
    }

    /// 按 Emby 的 PascalCase 字段名编码。
    ///
    /// - Parameter encoder: 编码器。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mediaSources, forKey: .mediaSources)
        try container.encodeIfPresent(playSessionId, forKey: .playSessionId)
        try container.encodeIfPresent(errorCode?.rawValue, forKey: .errorCode)
    }
}

/// 播放协商失败原因，对应 `PlaybackErrorCode`。
///
/// 取值来源（已核实）：<https://dev.emby.media/reference/RestAPI/MediaInfoService/postItemsByIdPlaybackinfo.html>
/// —— `NotAllowed`、`NoCompatibleStream`、`RateLimitExceeded`。
public struct PlaybackErrorCode: EmbyStringEnum {
    /// 原始字符串。
    public let rawValue: String

    /// 以原始字符串构造。
    ///
    /// - Parameter rawValue: 服务端返回值。
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// 当前用户/设备不被允许播放（如家长控制、并发流限制）。
    public static let notAllowed = PlaybackErrorCode(rawValue: "NotAllowed")
    /// 没有与 `DeviceProfile` 兼容的流。
    public static let noCompatibleStream = PlaybackErrorCode(rawValue: "NoCompatibleStream")
    /// 触发服务器限流。
    public static let rateLimitExceeded = PlaybackErrorCode(rawValue: "RateLimitExceeded")
}
