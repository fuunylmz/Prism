import Foundation

/// 播放方式：Prism 与 Emby 服务器协商后，对「这个片源怎么播」的三选一结论。
///
/// 定义依据（已核实）：<https://dev.emby.media/doc/restapi/Playback-Guidelines.html>
///
/// | 方式 | 官方定义 | Prism 的实际行为 |
/// |---|---|---|
/// | ``directPlay`` | 客户端**直接读文件系统**（用 `Path`），服务器被绕过 | 用服务器给的静态流地址（`DirectStreamUrl`，含 `Static=true`）原样拉取，客户端完整解码 |
/// | ``directStream`` | 客户端从服务器**原样拉流**，不编码、不重封装 | 视频流直通、容器/封装由服务器处理（如 MKV → fMP4/TS） |
/// | ``transcode`` | 服务器编码后再给客户端 | 走 HLS（`TranscodingUrl`，`master.m3u8`） |
///
/// - Important: 这里的 `directPlay` 与官方「读本地文件」在语义上略有差异：
///   Prism 是网络客户端，拿不到服务器的文件系统路径，所以「直连」= 以静态方式拉原始字节，
///   不在服务端做任何编码。判定仍严格按官方推荐算法（见 ``PlaybackNegotiator``）。
///
/// - Note: 进度上报要把这个值填进 `PlayMethod` 字段，见 ``embyPlayMethod``。
public enum PlaybackMethod: Sendable, Equatable, Hashable {
    /// 原文件直连：服务器不解码、不重封装，客户端完整解码。
    case directPlay

    /// 直封：视频流直通，容器/封装由服务器处理（可能改封装，如 MKV → fMP4/TS）。
    case directStream

    /// 完整转码：服务器编码后以 HLS 交付。
    case transcode
}

public extension PlaybackMethod {
    /// 对应 Emby `PlaybackStartInfo.PlayMethod` 的取值。
    ///
    /// 取值来源（已核实）：<https://dev.emby.media/doc/restapi/Playback-Check-ins.html>
    /// 与 <https://dev.emby.media/reference/RestAPI/PlaystateService/postSessionsPlaying.html>
    /// —— 枚举为 `Transcode` / `DirectStream` / `DirectPlay`（PascalCase，与 ``rawValue`` 一致）。
    ///
    /// 进度上报层直接用它填 `PlayMethod`，不要自己拼字符串。
    var embyPlayMethod: String {
        switch self {
        case .directPlay: "DirectPlay"
        case .directStream: "DirectStream"
        case .transcode: "Transcode"
        }
    }

    /// 是否为「服务端不重新编码」的路径（直连或直封）。
    ///
    /// 两种方式都可以在客户端自由 seek；``transcode`` 则必须带 `StartTimeTicks` 重新起流。
    /// 依据：<https://dev.emby.media/doc/restapi/Video-Streaming.html>（“When direct streaming,
    /// the file will be served statically and client-side seeking will be possible.
    /// When transcoding, this will not be possible.”）
    var isStreamCopy: Bool {
        switch self {
        case .directPlay, .directStream: true
        case .transcode: false
        }
    }
}
