import Foundation
import PrismCore

// MARK: - 播放协商

/// `POST /Items/{itemId}/PlaybackInfo` —— 播放协商（拿媒体源、`PlaySessionId`、播放 URL）。
///
/// 官方文档：<https://dev.emby.media/reference/RestAPI/MediaInfoService/postItemsByIdPlaybackinfo.html>
///
/// 请求体是 ``PlaybackInfoRequest``（含 ``DeviceProfile``），返回 ``PlaybackInfoResponse``。
///
/// ```swift
/// let info: PlaybackInfoResponse = try await client.send(
///     PlaybackInfoEndpoint(
///         itemId: item.id,
///         userId: userId,
///         profile: .prismMacOS(maxStreamingBitrate: 20_000_000),
///         startTimeTicks: resumeAt
///     )
/// )
/// ```
///
/// ## Emby 与 Jellyfin 的签名差异
///
/// | | Emby | Jellyfin |
/// |---|---|---|
/// | `POST /Items/{id}/PlaybackInfo` | 官方只声明 **body**，无 query 参数 | 同时有 query 参数 **和** body |
///
/// 本端点**默认只带 `UserId` query**（任务书要求，且 Emby 会忽略多余 query 参数），
/// body 里也写了 `UserId`。
///
/// 【待验证】Emby 是否严格校验未知 query 参数：分别用「只 body」「只 query」「两者都发」
/// 请求 Emby 4.8 / 4.9 / Jellyfin 10.9，对比返回的 `MediaSources` 是否随 `DeviceProfile` 变化。
/// 验证方法见 `docs/research/emby-api.md` §16.3 第 1 条。
public struct PlaybackInfoEndpoint: EmbyEndpoint {
    /// 条目 id。
    public let itemId: String

    /// 用户 id。
    public let userId: String

    /// 请求体。
    public let request: PlaybackInfoRequest

    /// 以条目 id、用户 id 与能力描述创建。
    ///
    /// - Parameters:
    ///   - itemId: 条目 id。
    ///   - userId: 用户 id。
    ///   - profile: 客户端能力描述。
    ///   - startTimeTicks: 起播位置。
    ///   - mediaSourceId: 指定媒体源（多版本时）。
    public init(
        itemId: String,
        userId: String,
        profile: DeviceProfile? = nil,
        startTimeTicks: Ticks? = nil,
        mediaSourceId: String? = nil
    ) {
        self.itemId = itemId
        self.userId = userId
        var request = PlaybackInfoRequest(
            itemId: itemId,
            userId: userId,
            deviceProfile: profile,
            startTimeTicks: startTimeTicks
        )
        request.mediaSourceId = mediaSourceId
        self.request = request
    }

    /// 以完整请求体创建（需要设置 `MaxAudioChannels` / 音轨等字段时用）。
    ///
    /// - Parameters:
    ///   - itemId: 条目 id。
    ///   - userId: 用户 id。
    ///   - request: 请求体。
    public init(itemId: String, userId: String, request: PlaybackInfoRequest) {
        self.itemId = itemId
        self.userId = userId
        self.request = request
    }

    /// `/Items/{itemId}/PlaybackInfo`。
    public var path: String { "/Items/\(itemId)/PlaybackInfo" }

    /// `POST`。
    public var method: HTTPMethod { .post }

    /// `UserId`（Emby 侧读 body，Jellyfin 侧读 query；两边都给）。
    public var query: [String: String] {
        var accumulator = QueryAccumulator()
        accumulator.put("UserId", userId)
        return accumulator.values
    }

    /// 请求体（PascalCase，`DeviceProfile` 写成单个对象）。
    public var body: Data? {
        try? EmbyJSON.encode(request)
    }

    /// JSON 请求体。
    public var contentType: String? { "application/json" }
}

// MARK: - 开始播放

/// `POST /Sessions/Playing` —— 开始播放上报。
///
/// 官方文档：<https://dev.emby.media/reference/RestAPI/PlaystateService/postSessionsPlaying.html>
/// 语义说明：<https://dev.emby.media/doc/restapi/Playback-Check-ins.html>
///
/// 请求体是 ``PlaybackProgressReport``（对应 `PlaybackStartInfo`，与 `PlaybackProgressInfo`
/// 字段完全相同）。返回 200 + 空 body。
///
/// - Important: 必带 `PlayMethod`、`PlaySessionId`、`MediaSourceId`、`PositionTicks`，
///   否则服务器无法把进度挂到正确的会话上。
public struct PlayingStartEndpoint: EmbyEndpoint {
    /// 上报内容。
    public let report: PlaybackProgressReport

    /// 以上报内容创建。
    ///
    /// - Parameter report: 上报内容。
    public init(report: PlaybackProgressReport) {
        self.report = report
    }

    /// `/Sessions/Playing`。
    public var path: String { "/Sessions/Playing" }

    /// `POST`。
    public var method: HTTPMethod { .post }

    /// 请求体。
    public var body: Data? {
        try? EmbyJSON.encode(report)
    }

    /// JSON 请求体。
    public var contentType: String? { "application/json" }
}

// MARK: - 进度上报

/// `POST /Sessions/Playing/Progress` —— 播放进度上报。
///
/// 官方文档：<https://dev.emby.media/reference/RestAPI/PlaystateService/postSessionsPlayingProgress.html>
///
/// 节奏（已核实，<https://dev.emby.media/doc/restapi/Playback-Check-ins.html>）：
/// - 每 **10 秒**自动上报一次（`EventName = TimeUpdate`）；
/// - 用户每次交互后**立即**上报（暂停 / 恢复 / 音量 / 切轨 / 倍速…）。
///
/// 服务器自身每秒递增进度，客户端不需要比 10 秒更频繁。
///
/// - Note: 暂停 / 恢复**不是**独立端点：发本端点，`EventName = Pause|Unpause` 且
///   `IsPaused = true|false`。
public struct PlayingProgressEndpoint: EmbyEndpoint {
    /// 上报内容。
    public let report: PlaybackProgressReport

    /// 以上报内容创建。
    ///
    /// - Parameter report: 上报内容。
    public init(report: PlaybackProgressReport) {
        self.report = report
    }

    /// `/Sessions/Playing/Progress`。
    public var path: String { "/Sessions/Playing/Progress" }

    /// `POST`。
    public var method: HTTPMethod { .post }

    /// 请求体。
    public var body: Data? {
        try? EmbyJSON.encode(report)
    }

    /// JSON 请求体。
    public var contentType: String? { "application/json" }
}

// MARK: - 停止播放

/// `POST /Sessions/Playing/Stopped` —— 停止播放上报（写最终进度）。
///
/// 官方文档：<https://dev.emby.media/reference/RestAPI/PlaystateService/postSessionsPlayingStopped.html>
///
/// 请求体是 ``PlaybackStopReport``（`PlaybackStopInfo`，**14 个字段**）。
///
/// - Important: 官方文档说停止请求「与开始请求内容完全相同」，但 schema 只有 14 个字段，
///   **没有** `PlayMethod` / `IsPaused` / `VolumeLevel` / `CanSeek` / `AudioStreamIndex` /
///   `SubtitleStreamIndex`。本端点按 schema 实现。
public struct PlayingStoppedEndpoint: EmbyEndpoint {
    /// 上报内容。
    public let report: PlaybackStopReport

    /// 以上报内容创建。
    ///
    /// - Parameter report: 上报内容。
    public init(report: PlaybackStopReport) {
        self.report = report
    }

    /// `/Sessions/Playing/Stopped`。
    public var path: String { "/Sessions/Playing/Stopped" }

    /// `POST`。
    public var method: HTTPMethod { .post }

    /// 请求体。
    public var body: Data? {
        try? EmbyJSON.encode(report)
    }

    /// JSON 请求体。
    public var contentType: String? { "application/json" }
}
