import Foundation
import PrismCore

/// 协商结果：引擎需要的全部信息，与具体引擎无关。
///
/// 一次 `PlaybackInfo` + 一次判定，产出恰好一个 ``PlaybackPlan``；
/// 播放层（含 AetherEngine 适配器）只需要 `url` / `headers` / `startPosition` / 轨道序号，
/// **不需要也不应该**再做一次「能不能直连」的判断。
///
/// - Important: `url` 一定是**绝对 URL**。服务器返回的 `DirectStreamUrl` / `TranscodingUrl`
///   是相对路径（`/videos/…/stream?...`），协商时已按服务器根地址补全。
public struct PlaybackPlan: Sendable, Equatable {
    /// 选定的播放方式。
    public let method: PlaybackMethod

    /// 可直接交给播放引擎的绝对 URL（已增补续播位置与轨道参数）。
    public let url: URL

    /// 拉流时需要携带的 HTTP 头（Emby 鉴权头）。
    ///
    /// Emby 的播放 URL 里通常已内嵌 `api_key`，所以这个字典在多数场景为空；
    /// 非空时引擎应把它传给 HTTP 加载器（AetherEngine 的 `options.httpHeaders`）。
    public let headers: [String: String]

    /// 选中的媒体源 id（进度上报的 `MediaSourceId` 必须回传它）。
    public let mediaSourceId: String

    /// 本次播放会话 id（进度上报与转码 URL 都要用）。
    public let playSessionId: String?

    /// 起播位置。
    public let startPosition: Ticks

    /// 音轨序号（`MediaStream.Index`，不是数组下标）。
    public let audioStreamIndex: Int?

    /// 字幕序号（`MediaStream.Index`）；`nil` 表示关闭字幕。
    public let subtitleStreamIndex: Int?

    /// 时长（来自媒体源，缺失时回退到条目的 `RunTimeTicks`）。
    ///
    /// - Important: 这只是「协商时已知的时长」。引擎 `load()` 刚返回时读到的时长可能是 0，
    ///   见 `docs/ARCHITECTURE.md` §3.5 坑 1；UI 应以引擎事件为准，这里只用于提前画进度条。
    public let duration: Ticks?

    /// 为什么选了这个方式（用于日志与「为什么转码」提示）。
    public let reason: NegotiationReason

    /// 完整初始化。
    ///
    /// - Parameters:
    ///   - method: 播放方式。
    ///   - url: 绝对播放 URL。
    ///   - headers: 鉴权头。
    ///   - mediaSourceId: 媒体源 id。
    ///   - playSessionId: 播放会话 id。
    ///   - startPosition: 起播位置。
    ///   - audioStreamIndex: 音轨序号。
    ///   - subtitleStreamIndex: 字幕序号。
    ///   - duration: 时长。
    ///   - reason: 判定原因。
    public init(
        method: PlaybackMethod,
        url: URL,
        headers: [String: String] = [:],
        mediaSourceId: String,
        playSessionId: String? = nil,
        startPosition: Ticks = .zero,
        audioStreamIndex: Int? = nil,
        subtitleStreamIndex: Int? = nil,
        duration: Ticks? = nil,
        reason: NegotiationReason
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.mediaSourceId = mediaSourceId
        self.playSessionId = playSessionId
        self.startPosition = startPosition
        self.audioStreamIndex = audioStreamIndex
        self.subtitleStreamIndex = subtitleStreamIndex
        self.duration = duration
        self.reason = reason
    }

    /// 是否需要服务端转码（UI 可据此显示「正在转码」角标）。
    public var isTranscoding: Bool { method == .transcode }
}

/// 协商判定原因：为什么选了这个播放方式。
///
/// 这个枚举是**给用户和日志看的**，不是给引擎用的。它让「为什么转码」这类问题
/// 不需要翻服务器日志：直接 `plan.reason` 就能说清是容器、编码、码率还是字幕导致的。
///
/// 取值语义与 ``PlaybackNegotiator`` 的判定顺序一一对应；
/// 服务端给出的 `TranscodeReasons`（见 <https://dev.emby.media/doc/restapi/> 的
/// `TranscodingUrl` 参数）也会被映射到这里的 case，便于对照排查。
public enum NegotiationReason: Sendable, Equatable {
    /// 直连：服务器标记 `SupportsDirectPlay == true`，且容器/编码都在本地能力描述里。
    case directPlaySupported

    /// 容器不被本地能力描述支持（例如 MKV 在纯 AVPlayer 路径上不可直连）。
    case containerNotSupported(String)

    /// 视频编码不被支持（如 `vc1`、`mpeg2video`）。
    case videoCodecNotSupported(String)

    /// 音频编码不被支持（如 `dts`、`truehd`）。
    case audioCodecNotSupported(String)

    /// 字幕必须烧录进画面，因此必须转码。
    case subtitleBurnedIn(String)

    /// 码率超过用户设定的上限（参数依次为源码率与上限，单位 bps）。
    case bitrateExceeded(Int, limit: Int)

    /// 用户显式要求转码（调试 / 兼容用）。
    case userForcedTranscode

    /// 直封回退：直连不可用、改由直封承担（携带人类可读说明）；
    /// 也是「既不能直连也不能直封」时的兜底原因。
    case directStreamFallback(String)
}

public extension NegotiationReason {
    /// 面向用户/日志的一句话说明（中文）。
    ///
    /// UI 若要做本地化，按 case 自己映射；这里给的是日志与调试面板用的稳定文案。
    var localizedDescription: String {
        switch self {
        case .directPlaySupported:
            "可直接播放（服务器标记支持直连，容器与编码均在本地能力范围内）"
        case let .containerNotSupported(container):
            "容器 \(container) 不在本地支持列表内"
        case let .videoCodecNotSupported(codec):
            "视频编码 \(codec) 不受支持"
        case let .audioCodecNotSupported(codec):
            "音频编码 \(codec) 不受支持"
        case let .subtitleBurnedIn(description):
            "字幕「\(description)」必须烧录进画面"
        case let .bitrateExceeded(bitrate, limit):
            "码率 \(bitrate / 1_000_000) Mbps 超过上限 \(limit / 1_000_000) Mbps"
        case .userForcedTranscode:
            "用户要求强制转码"
        case let .directStreamFallback(detail):
            detail
        }
    }
}
