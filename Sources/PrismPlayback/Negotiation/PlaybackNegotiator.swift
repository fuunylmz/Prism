import Foundation
import EmbyAPI
import PrismCore

/// 播放协商：把「服务器给了什么」变成「我们怎么播」。
///
/// ## 职责边界
///
/// 协商层**不 import 任何播放内核**，只产出 ``PlaybackPlan``（URL + 方式 + 轨道 + 原因）。
/// 引擎适配器拿到 `PlaybackPlan` 后直接 `load`，不再做第二次能力判断 ——
/// 判定逻辑只存在于一个地方，出问题时只有一处要看。
///
/// ## 判定顺序（严格按官方推荐算法 + 实测修正）
///
/// 官方算法（已核实）：<https://dev.emby.media/doc/restapi/Playback-Guidelines.html>
/// Step 1 Direct Play → Step 2 Direct Stream（含码率约束）→ Step 3 Transcode。
/// Prism 不自己实现「算哪些源能直连」—— 那套计算依赖 `DeviceProfile` 与文件元数据，
/// 服务器已经算完了，结果就在 `MediaSource.SupportsDirectPlay` / `SupportsDirectStream` 里。
/// 我们只做「读标志 + 本地能力复核 + 用户偏好」。
///
/// ## ⚠️ 核心陷阱：`DirectStreamUrl` 存在 ≠ 能直封
///
/// 抓包实证：**需要转码时 Emby 照样返回 `DirectStreamUrl`**，其值常常与 `TranscodingUrl`
/// 完全相同（都是 `master.m3u8?...&TranscodeReasons=...`）。
/// 因此「能不能直封」**只能看 `SupportsDirectStream` 布尔值**，绝不能看 `DirectStreamUrl` 是否非空。
///
/// - 证据（真实会话 JSON，2026-10-21 逐字核对）：<https://emby.media/community/topic/92430-session-playstate-mediasourceid-session-fullplayingitemgetmediasources>
///   —— 该样例 4 个媒体源全部是 `"SupportsDirectStream": false`、`"SupportsDirectPlay": false`，
///   却仍然返回了
///   `"DirectStreamUrl": "/videos/58234/master.m3u8?…&TranscodeReasons=ContainerBitrateExceedsLimit"`，
///   且与 `"TranscodingUrl"` **逐字符相同**。
/// - 回归测试：`Tests/PrismPlaybackTests/NegotiationTests.swift` 的
///   `NegotiationDirectStreamTrapTests`（三条：陷阱本体 / 两个 URL 不同时选哪个 / 缺 `TranscodingUrl` 时抛错）。
///
/// 所以本类型的 `directStreamURL` 只在**已经判定为直连/直封之后**才被读取，
/// 判定过程完全不碰它；反过来，判定为转码时也**绝不**拿它顶替缺失的 `TranscodingUrl`
/// （见 ``NegotiationError/missingPlaybackURL(method:mediaSourceId:)``）。
///
/// ## 线程模型
///
/// 纯值类型、无状态、无 I/O，可在任意线程/actor 调用；所有依赖（能力描述、偏好、
/// 服务器地址、鉴权头）在 `init` 时快照。
public struct PlaybackNegotiator: Sendable {
    /// 服务器根地址（用于把相对播放地址补全）。
    ///
    /// 必须是用户配置的那个地址，**含子路径**（`https://host/emby` 不能截成 `https://host`）。
    public let baseURL: URL

    /// 用户偏好快照。
    public let settings: PlaybackPreferences

    /// 客户端能力描述（默认 ``DeviceProfile/prismMacOS(maxStreamingBitrate:)``）。
    ///
    /// 它的作用是**本地复核**：服务器的 `Supports*` 标志本来就是按它算的，
    /// 但服务端版本差异、插件改写都可能让标志失真，所以再用同一份 profile 校验一遍容器/编码。
    public let profile: DeviceProfile

    /// 拉流时要携带的 HTTP 头（Emby 鉴权头）。
    ///
    /// 约定：``PlaybackPlan/headers`` 原样输出它；其中 `X-Emby-Token` 的值还会被当作
    /// `api_key` 查询参数的兜底（服务器返回的 URL 里已有 `api_key` 时不覆盖）。
    public let authHeaders: [String: String]

    /// 字幕烧录判定器。
    public let subtitleDecider: SubtitleBurnInDecider

    /// URL 增补器。
    public let urlBuilder: TranscodeURLBuilder

    /// 创建协商器。
    ///
    /// - Parameters:
    ///   - profile: 客户端能力描述，默认 macOS 预设。
    ///   - settings: 用户偏好，默认 ``PlaybackPreferences/default``。
    ///   - baseURL: 服务器根地址（**必填**：服务器返回的是相对路径，
    ///     没有根地址就产不出可播的绝对 URL）。
    ///   - authHeaders: 拉流用的鉴权头，默认空。
    public init(
        profile: DeviceProfile = .prismMacOS(),
        settings: PlaybackPreferences = .default,
        baseURL: URL,
        authHeaders: [String: String] = [:]
    ) {
        self.profile = profile
        self.settings = settings
        self.baseURL = baseURL
        self.authHeaders = authHeaders
        self.subtitleDecider = SubtitleBurnInDecider(preferences: settings)
        self.urlBuilder = TranscodeURLBuilder(baseURL: baseURL)
    }

    /// 协商一次播放。
    ///
    /// - Parameters:
    ///   - item: 目标条目（只用到 `id` 与作为时长兜底的 `runTime`）。
    ///   - info: 服务器返回的 `PlaybackInfoResponse`。
    ///   - startPosition: 起播位置（续播）；负数按 0 处理。
    ///   - audioStreamIndex: 指定音轨（`MediaStream.Index`）；`nil` = 用偏好或服务器默认。
    ///   - subtitleStreamIndex: 指定字幕；`nil` = 关闭字幕（不等于「用服务器默认」），
    ///     `-1` 同样视为关闭。
    /// - Returns: 可直接交给引擎的 ``PlaybackPlan``。
    /// - Throws: ``NegotiationError``（无媒体源 / 服务器错误码 / 缺少 URL）。
    public func negotiate(
        item: MediaItem,
        info: PlaybackInfoResponse,
        startPosition: Ticks = .zero,
        audioStreamIndex: Int? = nil,
        subtitleStreamIndex: Int? = nil
    ) throws -> PlaybackPlan {
        if let errorCode = info.errorCode {
            throw NegotiationError.notPlayable(errorCode)
        }
        guard !info.mediaSources.isEmpty else {
            throw NegotiationError.noMediaSources(itemId: item.id)
        }

        let source = selectSource(from: info.mediaSources)
        let position = startPosition < .zero ? Ticks(0) : startPosition

        let audioStream = resolveAudioStream(in: source, requested: audioStreamIndex)
        let subtitleStream = resolveSubtitleStream(in: source, requested: subtitleStreamIndex)
        let burnIn = subtitleStream.map { subtitleDecider.requiresBurnIn($0) } ?? false

        let decision = decide(
            source: source,
            audioStream: audioStream,
            subtitleStream: subtitleStream,
            burnInRequired: burnIn
        )

        let url = try buildURL(
            for: decision.method,
            source: source,
            itemId: item.id,
            playSessionId: info.playSessionId ?? source.playSessionId,
            position: position,
            audioStream: audioStream,
            subtitleStream: subtitleStream,
            burnInRequired: burnIn
        )

        return PlaybackPlan(
            method: decision.method,
            url: url,
            headers: authHeaders,
            mediaSourceId: source.id,
            playSessionId: info.playSessionId ?? source.playSessionId,
            startPosition: position,
            audioStreamIndex: audioStream?.index,
            subtitleStreamIndex: subtitleStream?.index,
            duration: source.runTime ?? item.runTime,
            reason: decision.reason
        )
    }
}

// MARK: - 选源

extension PlaybackNegotiator {
    /// 按官方 Step 1 选源：优先第一个「服务器说能直连」的源，否则取第一个。
    ///
    /// 依据：<https://dev.emby.media/doc/restapi/Playback-Guidelines.html>
    /// （Step 1 算直连源数量：0 个进 Step 2；1 个直接播；多个让用户选）。
    /// Prism v1 不做多版本选择弹窗，按「第一个可直连的，否则第一个」降级 ——
    /// 多版本 UI 属于后续工单。
    ///
    /// - Parameter sources: `PlaybackInfoResponse.MediaSources`。
    /// - Returns: 选中的媒体源。
    func selectSource(from sources: [MediaSource]) -> MediaSource {
        if settings.preferDirectPlay, let directPlayable = sources.first(where: \.supportsDirectPlay) {
            return directPlayable
        }
        // 调用方保证 sources 非空（`negotiate` 已提前 guard）。
        return sources[0]
    }
}

// MARK: - 轨道解析

extension PlaybackNegotiator {
    /// 解析实际使用的音轨。
    ///
    /// 优先级：调用方指定 → 用户偏好语言 → 服务器默认音轨。
    ///
    /// - Parameters:
    ///   - source: 媒体源。
    ///   - requested: 调用方指定的序号。
    /// - Returns: 命中的流；`nil` 表示服务器没给音轨信息（如纯视频文件）。
    func resolveAudioStream(in source: MediaSource, requested: Int?) -> MediaStream? {
        let audios = source.streams(ofType: .audio)
        if let requested {
            // 序号可能不在流列表里（服务器数据不全），仍然尊重调用方，回退成一条占位流。
            return audios.first { $0.index == requested } ?? MediaStream(index: requested, type: .audio)
        }
        if let language = settings.preferredAudioLanguage, !language.isEmpty,
           let match = audios.first(where: { Self.matches(language: language, stream: $0) }) {
            return match
        }
        return source.defaultAudioStream
    }

    /// 解析实际使用的字幕轨。
    ///
    /// 优先级：调用方指定（`-1` = 关闭）→ 用户偏好语言 → 关闭。
    ///
    /// - Important: 「调用方没指定」时**不会**自动选服务器默认字幕。
    ///   原因是默认字幕可能正好是 PGS，会自动把一次本来能直连的播放变成转码；
    ///   字幕开关属于 UI 层的明确选择。
    ///
    /// - Parameters:
    ///   - source: 媒体源。
    ///   - requested: 调用方指定的序号。
    /// - Returns: 命中的流；`nil` 表示关闭字幕。
    func resolveSubtitleStream(in source: MediaSource, requested: Int?) -> MediaStream? {
        let subtitles = source.streams(ofType: .subtitle)
        if let requested {
            guard requested >= 0 else { return nil }
            return subtitles.first { $0.index == requested } ?? MediaStream(index: requested, type: .subtitle)
        }
        if let language = settings.preferredSubtitleLanguage, !language.isEmpty {
            return subtitles.first { Self.matches(language: language, stream: $0) }
        }
        return nil
    }

    /// 语言匹配（大小写不敏感，支持 `zh` / `chi` / `zho` 这类三字母代码的前缀匹配）。
    ///
    /// - Parameters:
    ///   - language: 期望语言。
    ///   - stream: 媒体流。
    /// - Returns: 是否匹配。
    static func matches(language: String, stream: MediaStream) -> Bool {
        let wanted = language.lowercased()
        let candidates = [stream.language, stream.displayLanguage]
            .compactMap { $0?.lowercased() }
            .filter { !$0.isEmpty }
        return candidates.contains { $0 == wanted || $0.hasPrefix(wanted) || wanted.hasPrefix($0) }
    }
}

// MARK: - 判定

extension PlaybackNegotiator {
    /// 判定播放方式与原因。
    ///
    /// - Parameters:
    ///   - source: 选中的媒体源。
    ///   - audioStream: 实际音轨。
    ///   - subtitleStream: 实际字幕轨。
    ///   - burnInRequired: 字幕是否必须烧录。
    /// - Returns: 方式 + 原因。
    func decide(
        source: MediaSource,
        audioStream: MediaStream?,
        subtitleStream: MediaStream?,
        burnInRequired: Bool
    ) -> (method: PlaybackMethod, reason: NegotiationReason) {
        // 1. 用户强制转码（调试/兼容），优先级最高。
        if settings.forceTranscode {
            return (.transcode, .userForcedTranscode)
        }

        // 2. 码率超限：官方 Step 2 明确要求「在码率内」才能直封。
        if let limit = settings.bitrateLimitBps, let bitrate = effectiveBitrate(of: source), bitrate > limit {
            return (.transcode, .bitrateExceeded(bitrate, limit: limit))
        }

        // 3. 字幕必须烧录 → 必然转码（烧录是视频滤镜，无法与「不转码」共存）。
        if burnInRequired, let subtitleStream {
            return (.transcode, .subtitleBurnedIn(subtitleStream.displayName))
        }

        // 4. 本地复核直连能力：服务器说能直连，还要容器/编码真的在能力描述里。
        let blocker = directPlayBlocker(for: source, audioStream: audioStream)

        if source.supportsDirectPlay, blocker == nil {
            return (.directPlay, .directPlaySupported)
        }

        // 5. 直封：只看 `SupportsDirectStream` 布尔值（**绝不看 DirectStreamUrl 是否存在**）。
        if source.supportsDirectStream, videoIsCopyable(source) {
            // 直连被什么挡住，就是直封的原因（典型：容器需要重封装）。
            if let blocker {
                return (.directStream, blocker)
            }
            return (.directStream, .directStreamFallback("服务器建议直封（视频流直通，容器由服务端处理）"))
        }

        // 6. 转码：原因优先取服务器写在 URL 里的 `TranscodeReasons`，其次用本地诊断。
        if let serverReason = serverTranscodeReason(for: source, subtitleStream: subtitleStream) {
            return (.transcode, serverReason)
        }
        if let blocker {
            return (.transcode, blocker)
        }
        return (.transcode, .directStreamFallback("服务器未提供可直连或可直封的流"))
    }

    /// 实际用于码率比较的码率（bps）。
    ///
    /// 优先 `MediaSource.Bitrate`（整条流的总码率）；缺失时用视频轨码率 + 音轨码率估算。
    ///
    /// - Parameter source: 媒体源。
    /// - Returns: 码率；完全未知时为 `nil`（此时不做码率判定，交给服务器）。
    func effectiveBitrate(of source: MediaSource) -> Int? {
        if let bitrate = source.bitrate, bitrate > 0 { return bitrate }
        let video = source.videoStream?.bitRate ?? 0
        let audio = source.streams(ofType: .audio).compactMap(\.bitRate).reduce(0, +)
        let total = video + audio
        return total > 0 ? total : nil
    }

    /// 直连能力复核：返回**挡住直连的原因**，`nil` 表示可以直连。
    ///
    /// 匹配规则（与 Emby 服务端一致）：`DirectPlayProfile` 的 `Container` / `VideoCodec` /
    /// `AudioCodec` 都是逗号分隔列表，大小写不敏感；某一项为空表示「不限制」。
    ///
    /// - Parameters:
    ///   - source: 媒体源。
    ///   - audioStream: 实际音轨。
    /// - Returns: 阻止直连的原因；可直连时为 `nil`。
    func directPlayBlocker(for source: MediaSource, audioStream: MediaStream?) -> NegotiationReason? {
        let isVideo = source.videoStream != nil
        let candidates = profile.directPlayProfiles.filter { candidate in
            guard let type = candidate.type else { return true }
            return isVideo ? type == .video : type == .audio
        }
        guard !candidates.isEmpty else {
            return .containerNotSupported(source.container ?? "未知容器")
        }

        let container = source.container?.lowercased()
        let videoCodec = source.videoStream?.codec?.lowercased()
        let audioCodec = audioStream?.codec?.lowercased()

        let containerMatches = candidates.filter { Self.list($0.container, contains: container) }
        if containerMatches.isEmpty {
            return .containerNotSupported(container ?? "未知容器")
        }

        let videoMatches = containerMatches.filter { Self.list($0.videoCodec, contains: videoCodec) }
        if videoMatches.isEmpty {
            return .videoCodecNotSupported(videoCodec ?? "未知编码")
        }

        let audioMatches = videoMatches.filter { Self.list($0.audioCodec, contains: audioCodec) }
        if audioMatches.isEmpty {
            return .audioCodecNotSupported(audioCodec ?? "未知编码")
        }

        return nil
    }

    /// 视频流能否原样直通（直封的前提）。
    ///
    /// 直封不改视频编码，所以视频编码必须在 `DirectPlayProfiles` 的视频编码列表里。
    /// 服务端的 `SupportsDirectStream` 通常已经包含了这个结论，这里只做兜底复核 ——
    /// 尤其防止「服务端为兼容旧 profile 返回 true，但当前 profile 已不再支持该编码」。
    ///
    /// - Parameter source: 媒体源。
    /// - Returns: 可直通（或无法判断）时为 `true`。
    func videoIsCopyable(_ source: MediaSource) -> Bool {
        guard let video = source.videoStream else { return true }
        guard let codec = video.codec?.lowercased(), !codec.isEmpty else { return true }

        let codecs = profile.directPlayProfiles
            .filter { $0.type == nil || $0.type == .video }
            .compactMap(\.videoCodec)
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }

        guard !codecs.isEmpty else { return true }
        return codecs.contains(codec)
    }

    /// 从服务器给的 `TranscodingUrl` 里读 `TranscodeReasons`，映射成本地原因。
    ///
    /// Emby 会在转码 URL 上附加 `TranscodeReasons=VideoCodecNotSupported` 这类逗号分隔列表，
    /// 这是排查「为什么转码」最快的入口（`docs/research/emby-api.md` §6.6）。
    ///
    /// 取值**逐个核实**过（◐ 来自 Jellyfin 的官方 OpenAPI，Emby 官方未公布完整清单，
    /// 但实测抓包里的取值与之完全一致）：
    /// <https://api.jellyfin.org/openapi/jellyfin-openapi-stable.json> → `components.schemas.TranscodeReason`。
    /// 本方法**只认确定已知的几个**，其余一律返回 `nil` 交给本地诊断，避免猜错。具体认的：
    /// `ContainerNotSupported`、`VideoCodecNotSupported`、`AudioCodecNotSupported`、
    /// `SubtitleCodecNotSupported`、`ContainerBitrateExceedsLimit`、
    /// `VideoBitrateNotSupported`、`AudioBitrateNotSupported`。
    ///
    /// - Parameters:
    ///   - source: 媒体源。
    ///   - subtitleStream: 实际字幕轨（用于 `SubtitleCodecNotSupported` 的文案）。
    /// - Returns: 映射成功的原因；无法映射时为 `nil`。
    func serverTranscodeReason(for source: MediaSource, subtitleStream: MediaStream?) -> NegotiationReason? {
        guard
            let rawURL = source.transcodingUrl,
            let components = URLComponents(string: rawURL),
            let value = components.queryItems?
                .first(where: { $0.name.caseInsensitiveCompare("TranscodeReasons") == .orderedSame })?
                .value
        else {
            return nil
        }

        let videoCodec = source.videoStream?.codec ?? "未知编码"
        let audioCodec = source.defaultAudioStream?.codec ?? "未知编码"

        for reason in value.split(separator: ",") {
            switch reason.trimmingCharacters(in: .whitespaces).lowercased() {
            case "containernotsupported":
                return .containerNotSupported(source.container ?? "未知容器")
            case "videocodecnotsupported":
                return .videoCodecNotSupported(videoCodec)
            case "audiocodecnotsupported":
                return .audioCodecNotSupported(audioCodec)
            case "subtitlecodecnotsupported":
                return .subtitleBurnedIn(subtitleStream?.displayName ?? "未知字幕")
            case "containerbitrateexceedslimit", "videobitratenotsupported", "audiobitratenotsupported":
                if let bitrate = effectiveBitrate(of: source), let limit = settings.bitrateLimitBps {
                    return .bitrateExceeded(bitrate, limit: limit)
                }
            default:
                continue
            }
        }
        return nil
    }

    /// 逗号分隔列表是否包含给定值（大小写不敏感）。
    ///
    /// - Parameters:
    ///   - list: 能力描述里的列表字符串（`nil` / 空串 = 不限制）。
    ///   - value: 待查值（`nil` / 空串 = 源未提供，无法证伪，视为匹配）。
    /// - Returns: 是否匹配。
    static func list(_ list: String?, contains value: String?) -> Bool {
        guard let list, !list.isEmpty else { return true }
        guard let value, !value.isEmpty else { return true }
        return list
            .split(separator: ",")
            .contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == value }
    }
}

// MARK: - URL 构造

extension PlaybackNegotiator {
    /// 按判定结果取/拼播放地址。
    ///
    /// - 直连/直封：优先服务器给的 `DirectStreamUrl`（已带 `Static=true` 与全部鉴权参数）；
    ///   服务器没给时按官方模板自拼静态流地址。
    /// - 转码：**必须**用 `TranscodingUrl`。缺失就抛错 —— 不许拿 `DirectStreamUrl` 顶替，
    ///   因为转码场景下它往往就是同一个 `master.m3u8`，顶替只会掩盖问题。
    ///
    /// - Parameters:
    ///   - method: 判定结果。
    ///   - source: 媒体源。
    ///   - itemId: 条目 id（自拼静态地址时用）。
    ///   - playSessionId: 播放会话 id。
    ///   - position: 起播位置。
    ///   - audioStream: 实际音轨。
    ///   - subtitleStream: 实际字幕轨。
    ///   - burnInRequired: 字幕是否必须烧录。
    /// - Returns: 绝对播放 URL。
    /// - Throws: ``NegotiationError/missingPlaybackURL(method:mediaSourceId:)`` 或
    ///   ``NegotiationError/invalidPlaybackURL(_:)``。
    func buildURL(
        for method: PlaybackMethod,
        source: MediaSource,
        itemId: String,
        playSessionId: String?,
        position: Ticks,
        audioStream: MediaStream?,
        subtitleStream: MediaStream?,
        burnInRequired: Bool
    ) throws -> URL {
        let apiKey = authHeaders.first { $0.key.caseInsensitiveCompare("X-Emby-Token") == .orderedSame }?.value

        // 字幕序号只在烧录时进 URL：官方明确写的是
        // “SubtitleStreamIndex (if burning into the video)”
        // <https://dev.emby.media/doc/restapi/Video-Streaming.html>
        let subtitleIndex = burnInRequired ? subtitleStream?.index : nil

        switch method {
        case .directPlay, .directStream:
            if let raw = source.directStreamUrl, !raw.isEmpty {
                return try urlBuilder.buildURL(
                    rawURL: raw,
                    startPosition: position,
                    audioStreamIndex: audioStream?.index,
                    subtitleStreamIndex: subtitleIndex,
                    apiKey: apiKey
                )
            }
            let path = urlBuilder.staticStreamPath(
                itemId: itemId,
                mediaSourceId: source.id,
                playSessionId: playSessionId
            )
            return try urlBuilder.buildURL(
                rawURL: path,
                startPosition: position,
                audioStreamIndex: audioStream?.index,
                subtitleStreamIndex: subtitleIndex,
                apiKey: apiKey
            )

        case .transcode:
            guard let raw = source.transcodingUrl, !raw.isEmpty else {
                throw NegotiationError.missingPlaybackURL(method: .transcode, mediaSourceId: source.id)
            }
            return try urlBuilder.buildURL(
                rawURL: raw,
                startPosition: position,
                audioStreamIndex: audioStream?.index,
                subtitleStreamIndex: subtitleIndex,
                apiKey: apiKey
            )
        }
    }
}
