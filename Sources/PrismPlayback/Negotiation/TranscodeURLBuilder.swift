import Foundation
import PrismCore

/// 把服务器给的播放地址补全、增补参数，得到最终可播 URL。
///
/// ## 为什么不自己拼 URL
///
/// Emby 返回的 `TranscodingUrl` 里带着**服务端算好的几十个参数**
/// （`VideoCodec`、`VideoBitrate`、`h264-profile`、`h264-level`、`SegmentContainer`、
/// `MinSegments`、`BreakOnNonKeyFrames`、`ManifestSubtitles`…），它们共同决定转码器怎么起。
/// 自己拼一份等价参数是徒劳的：少一个、错一个就是 `400 Bad Request`
/// （<https://dev.emby.media/doc/restapi/Http-Live-Streaming.html> 的参数表只是「可选项」，
/// 服务端还会读 `DeviceProfileId` 与设备能力）。
///
/// 所以本类型只做三件事：
/// 1. **补全**：把相对路径解析成绝对 URL（服务器可能挂在 `/emby` 这类子路径下）；
/// 2. **增补**：`StartTimeTicks` / `AudioStreamIndex` / `SubtitleStreamIndex` / `api_key`；
/// 3. **保留**：其余参数一个不动、顺序不变。
///
/// ## 参数语义（逐个核实）
///
/// | 参数 | 含义 | 来源 |
/// |---|---|---|
/// | `StartTimeTicks` | 起播偏移，单位 tick（1ms = 10000 ticks） | <https://dev.emby.media/reference/RestAPI/VideoService/getVideosByIdStream.html> |
/// | `AudioStreamIndex` | 使用哪条音轨；省略则用第一条 | 同上 |
/// | `SubtitleStreamIndex` | 使用哪条字幕；**仅在烧录进画面时传** | 同上 + <https://dev.emby.media/doc/restapi/Video-Streaming.html>（“SubtitleStreamIndex (if burning into the video)”） |
/// | `api_key` | 令牌的查询参数形式（等价于 `X-Emby-Token` 头） | <https://dev.emby.media/doc/restapi/User-Authentication.html> |
///
/// - Important: `StartTimeTicks` 只在**转码**时必需。直连/直封是静态流，客户端自己 seek
///   （“When direct streaming, the file will be served statically and client-side seeking
///   will be possible.” —— <https://dev.emby.media/doc/restapi/Video-Streaming.html>）。
///   这里仍然写进去：它是 `/Videos/{Id}/stream` 与 `master.m3u8` 共同声明的合法查询参数，
///   对静态流无害，且能让服务端在日志里看到续播位置。
public struct TranscodeURLBuilder: Sendable, Equatable {
    /// 服务器根地址（可含 `/emby` 这类子路径，**必须保留**）。
    public let baseURL: URL

    /// 以服务器根地址创建。
    ///
    /// - Parameter baseURL: 服务器根地址，例如 `https://host:8096` 或 `https://host/emby`。
    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// 把服务器返回的相对路径解析成绝对 URL。
    ///
    /// - Parameter rawURL: 服务器返回值，可能已是绝对 URL，也可能是 `/videos/…` 这类相对路径。
    /// - Returns: 绝对 URL。
    /// - Throws: ``NegotiationError/invalidPlaybackURL(_:)``（空串或无法解析）。
    public func absoluteURL(from rawURL: String) throws -> URL {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NegotiationError.invalidPlaybackURL(rawURL)
        }

        // 已经是绝对地址（Emby 在某些反向代理配置下会直接给全 URL）——原样使用。
        if let url = URL(string: trimmed), url.scheme != nil, url.host != nil {
            return url
        }

        // ⚠️ 不能用 `URL(string: trimmed, relativeTo: baseURL)`：以 "/" 开头的相对路径
        // 会被解析到**域名根**，把 `/emby` 这类子路径吃掉。必须手工拼。
        var root = baseURL.absoluteString
        while root.hasSuffix("/") { root.removeLast() }
        let path = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed

        guard let url = URL(string: root + path) else {
            throw NegotiationError.invalidPlaybackURL(rawURL)
        }
        return url
    }

    /// 在服务器给的播放地址上增补参数。
    ///
    /// 只增补、不重建：原有 query 项全部保留（含顺序），只改动下面四个键。
    ///
    /// - Parameters:
    ///   - rawURL: 服务器返回的地址（`DirectStreamUrl` / `TranscodingUrl`）。
    ///   - startPosition: 起播位置；`.zero` 时**移除**可能残留的 `StartTimeTicks`
    ///     （否则「从头播」会变成「从上次位置播」）。
    ///   - audioStreamIndex: 音轨序号；`nil` 表示不动原值。
    ///   - subtitleStreamIndex: 字幕序号；只在需要烧录时传，`nil` 表示不动原值。
    ///   - apiKey: 令牌；**仅在 URL 里没有 `api_key` 时**追加（服务器已经算好的一律不覆盖）。
    /// - Returns: 增补后的绝对 URL。
    /// - Throws: ``NegotiationError/invalidPlaybackURL(_:)``。
    public func buildURL(
        rawURL: String,
        startPosition: Ticks = .zero,
        audioStreamIndex: Int? = nil,
        subtitleStreamIndex: Int? = nil,
        apiKey: String? = nil
    ) throws -> URL {
        let absolute = try absoluteURL(from: rawURL)

        guard var components = URLComponents(url: absolute, resolvingAgainstBaseURL: false) else {
            throw NegotiationError.invalidPlaybackURL(rawURL)
        }

        var items = components.queryItems ?? []

        if startPosition > .zero {
            items = replacing(items, key: Self.startTimeTicksKey, value: "\(startPosition.rawValue)")
        } else {
            items.removeAll { $0.name.caseInsensitiveCompare(Self.startTimeTicksKey) == .orderedSame }
        }

        if let audioStreamIndex {
            items = replacing(items, key: Self.audioStreamIndexKey, value: "\(audioStreamIndex)")
        }

        if let subtitleStreamIndex {
            items = replacing(items, key: Self.subtitleStreamIndexKey, value: "\(subtitleStreamIndex)")
        }

        if let apiKey, !apiKey.isEmpty, !items.contains(where: { $0.name.caseInsensitiveCompare(Self.apiKeyKey) == .orderedSame }) {
            items.append(URLQueryItem(name: Self.apiKeyKey, value: apiKey))
        }

        components.queryItems = items.isEmpty ? nil : items

        guard let url = components.url else {
            throw NegotiationError.invalidPlaybackURL(rawURL)
        }
        return url
    }

    /// 自行拼一个静态直连/直封地址的**相对路径**（服务器没给 `DirectStreamUrl` 时用）。
    ///
    /// 模板依据：<https://dev.emby.media/doc/restapi/Video-Streaming.html>
    /// —— “To direct stream a video file, simply use the static=true parameter.”，
    /// 必需参数为 `Id`（path）、`MediaSourceId`、`PlaySessionId`。
    ///
    /// - Parameters:
    ///   - itemId: 条目 id（放进 path）。
    ///   - mediaSourceId: 媒体源 id。
    ///   - playSessionId: 播放会话 id。
    /// - Returns: 形如 `/Videos/{id}/stream?Static=true&…` 的相对路径。
    public func staticStreamPath(
        itemId: String,
        mediaSourceId: String,
        playSessionId: String?
    ) -> String {
        var raw = "/Videos/\(itemId)/stream?Static=true&MediaSourceId=\(mediaSourceId)"
        if let playSessionId, !playSessionId.isEmpty {
            raw += "&PlaySessionId=\(playSessionId)"
        }
        return raw
    }

    // MARK: - 内部

    /// `StartTimeTicks` 的查询键（PascalCase，与 Emby 参数表一致）。
    static let startTimeTicksKey = "StartTimeTicks"
    /// `AudioStreamIndex` 的查询键。
    static let audioStreamIndexKey = "AudioStreamIndex"
    /// `SubtitleStreamIndex` 的查询键（注意服务端还会生成一个复数形式的
    /// `SubtitleStreamIndexes`，那是另一回事，不要动它）。
    static let subtitleStreamIndexKey = "SubtitleStreamIndex"
    /// `api_key` 的查询键（小写 + 下划线，是 Emby/Jellyfin 的固定写法）。
    static let apiKeyKey = "api_key"

    /// 就地替换同名 query 项（保持位置不变）；不存在则追加。
    ///
    /// - Parameters:
    ///   - items: 现有 query 项。
    ///   - key: 键名（大小写不敏感匹配）。
    ///   - value: 新值。
    /// - Returns: 处理后的数组。
    private func replacing(_ items: [URLQueryItem], key: String, value: String) -> [URLQueryItem] {
        var result = items
        if let index = result.firstIndex(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) {
            result[index] = URLQueryItem(name: result[index].name, value: value)
        } else {
            result.append(URLQueryItem(name: key, value: value))
        }
        return result
    }
}
