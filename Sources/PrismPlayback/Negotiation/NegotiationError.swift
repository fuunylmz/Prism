import Foundation
import EmbyAPI
import PrismCore

/// 协商失败原因。
///
/// 与 ``PrismCore/EmbyError`` 分开，是因为这些失败**全部发生在本地判定阶段**
/// （服务器已经成功返回了 `PlaybackInfo`），既不是网络问题也不是鉴权问题，
/// 用 `EmbyError.serverUnreachable` 之类会误导用户与日志。
///
/// 调用方通常这样处理：能显示 ``message`` 就显示，无法播放就回退到剧集列表。
public enum NegotiationError: Error, Sendable, Equatable, Hashable {
    /// `PlaybackInfo` 成功返回，但 `MediaSources` 为空 —— 服务器没有可用片源。
    ///
    /// 常见原因：文件被删除、库未扫描完、或 `DeviceProfile` 与文件完全不兼容。
    case noMediaSources(itemId: String)

    /// 服务器明确返回了错误码（`NotAllowed` / `NoCompatibleStream` / `RateLimitExceeded`）。
    ///
    /// 依据（已核实）：<https://dev.emby.media/reference/RestAPI/MediaInfoService/postItemsByIdPlaybackinfo.html>
    /// 的 `PlaybackInfoResponse.ErrorCode`。
    case notPlayable(PlaybackErrorCode)

    /// 需要的播放 URL 字段缺失，无法构造可播地址。
    ///
    /// 例如：判定为 ``PlaybackMethod/transcode``，但 `MediaSource.TranscodingUrl` 为 `nil`。
    /// **此时绝不能拿 `DirectStreamUrl` 顶替** —— 它可能是服务端为转码准备的同一个
    /// `master.m3u8`（见 ``PlaybackNegotiator`` 的 `DirectStreamUrl` 说明），
    /// 顶替只会得到一个看似能播、实际参数错误的地址。
    case missingPlaybackURL(method: PlaybackMethod, mediaSourceId: String)

    /// 服务器返回的 URL 无法解析成合法地址。
    case invalidPlaybackURL(String)
}

public extension NegotiationError {
    /// 面向用户/日志的中文说明。
    var message: String {
        switch self {
        case let .noMediaSources(itemId):
            "服务器没有返回可播放的片源（条目 \(itemId)）"
        case let .notPlayable(code):
            "服务器拒绝播放：\(code.rawValue)"
        case let .missingPlaybackURL(method, mediaSourceId):
            "缺少 \(method) 所需的播放地址（媒体源 \(mediaSourceId)）"
        case let .invalidPlaybackURL(raw):
            "播放地址无法解析：\(raw)"
        }
    }
}
