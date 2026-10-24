import Foundation
import Testing
import EmbyAPI
import PrismCore
import PrismPlayback

// MARK: - 公共夹具

/// 测试用服务器根地址（**虚构**，见 `docs/BUILD_ENV.md` §6：禁止写入真实地址）。
///
/// 故意带 `/emby` 子路径：Emby 常挂在反向代理的子路径下，
/// 相对播放地址补全时**不能**把这个前缀吃掉。
private let testBaseURL = URL(string: "https://emby.test/emby")!

/// 解码 `PlaybackInfo` fixture。
///
/// - Parameter json: `Fixtures.playbackInfo*` 里的 JSON 字符串。
/// - Returns: 解码结果。
private func decodePlaybackInfo(_ json: String) throws -> PlaybackInfoResponse {
    try EmbyJSON.decode(PlaybackInfoResponse.self, from: Data(json.utf8))
}

/// 构造一个最小 `MediaItem`。
///
/// - Parameters:
///   - id: 条目 id。
///   - runTime: 时长。
/// - Returns: 测试用条目。
private func makeItem(id: String = "item-1", runTime: Ticks? = nil) -> MediaItem {
    MediaItem(id: id, name: "Test Item", type: .movie, serverId: "server-1", runTime: runTime)
}

/// 构造协商器。
///
/// - Parameters:
///   - settings: 用户偏好。
///   - headers: 鉴权头。
/// - Returns: 指向 ``testBaseURL`` 的协商器。
private func makeNegotiator(
    settings: PlaybackPreferences = .default,
    headers: [String: String] = [:]
) -> PlaybackNegotiator {
    PlaybackNegotiator(settings: settings, baseURL: testBaseURL, authHeaders: headers)
}

/// 取 URL 的 query 键值对（同名键后者覆盖前者，仅用于唯一键）。
///
/// - Parameter url: 目标 URL。
/// - Returns: 键值字典。
private func query(of url: URL) -> [String: String] {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    var result: [String: String] = [:]
    for item in items { result[item.name] = item.value ?? "" }
    return result
}

/// 取某个 query 键的**全部**取值（用于断言「没有重复追加」）。
///
/// - Parameters:
///   - url: 目标 URL。
///   - name: 键名。
/// - Returns: 按出现顺序排列的值数组。
private func queryValues(of url: URL, name: String) -> [String] {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return items.filter { $0.name == name }.map { $0.value ?? "" }
}

/// 构造一条视频流。
///
/// - Parameter codec: 视频编码。
/// - Returns: 测试用视频流。
private func videoStream(_ codec: String) -> MediaStream {
    MediaStream(index: 0, type: .video, codec: codec, isDefault: true, height: 1080, width: 1920, bitRate: 8_000_000)
}

/// 构造一条音轨。
///
/// - Parameters:
///   - codec: 音频编码。
///   - index: 流序号。
/// - Returns: 测试用音轨。
private func audioStream(_ codec: String, index: Int = 1) -> MediaStream {
    MediaStream(index: index, type: .audio, codec: codec, isDefault: true, channels: 6, bitRate: 640_000)
}

/// 构造一条图形字幕轨（PGS）。
///
/// - Parameter index: 流序号。
/// - Returns: 测试用 PGS 字幕。
private func pgsSubtitle(index: Int = 3) -> MediaStream {
    MediaStream(
        index: index,
        type: .subtitle,
        codec: "pgssub",
        language: "eng",
        displayTitle: "English PGS",
        isTextSubtitleStream: false
    )
}

/// 构造一条文本字幕轨（SRT）。
///
/// - Parameter index: 流序号。
/// - Returns: 测试用 SRT 字幕。
private func srtSubtitle(index: Int = 2) -> MediaStream {
    MediaStream(
        index: index,
        type: .subtitle,
        codec: "subrip",
        language: "chi",
        displayTitle: "Chinese SRT",
        isTextSubtitleStream: true,
        supportsExternalStream: true
    )
}

// MARK: - 直连

@Suite("播放协商 · 直连")
struct NegotiationDirectPlayTests {

    @Test("MKV/H.264 且 SupportsDirectPlay == true → directPlay，URL 取 DirectStreamUrl")
    func directPlayFromFixture() throws {
        let info = try decodePlaybackInfo(Fixtures.playbackInfoDirectPlay)
        let source = try #require(info.mediaSources.first)

        // 前置条件：fixture 就是「服务器说能直连」的真实形态。
        #expect(source.supportsDirectPlay)
        #expect(source.container == "mkv")
        #expect(source.videoStream?.codec == "hevc")

        let plan = try makeNegotiator().negotiate(item: makeItem(), info: info)

        #expect(plan.method == .directPlay)
        #expect(plan.reason == .directPlaySupported)
        #expect(plan.mediaSourceId == source.id)
        #expect(plan.playSessionId == "e643532a23ca4a60b2c70d4210c018a9")
        #expect(plan.duration == source.runTime)

        // URL 必须是服务器给的 DirectStreamUrl（静态流），且补全成绝对地址。
        #expect(plan.url.scheme == "https")
        #expect(plan.url.host == "emby.test")
        #expect(plan.url.path == "/emby/videos/0f8d0805a66f7ed429ecd8890146c7c3/stream")
        let q = query(of: plan.url)
        #expect(q["Static"]?.lowercased() == "true")
        #expect(q["MediaSourceId"] == source.id)
        #expect(q["api_key"] == "f3e2d1c0b9a87f6e5d4c3b2a1908f7e6")
        // 默认音轨被写进 URL。
        #expect(q["AudioStreamIndex"] == "1")
        #expect(plan.audioStreamIndex == 1)
        // 没选字幕 → 不写 SubtitleStreamIndex，也不烧录。
        #expect(plan.subtitleStreamIndex == nil)
        #expect(q["SubtitleStreamIndex"] == nil)
    }

    @Test("文本字幕（SRT）不需要烧录，不影响直连")
    func textSubtitleKeepsDirectPlay() throws {
        let info = try decodePlaybackInfo(Fixtures.playbackInfoDirectPlay)
        let plan = try makeNegotiator().negotiate(
            item: makeItem(),
            info: info,
            subtitleStreamIndex: 2
        )

        #expect(plan.method == .directPlay)
        #expect(plan.subtitleStreamIndex == 2)
        // 文本字幕由客户端渲染，不进 URL（官方：SubtitleStreamIndex 仅烧录时传）。
        #expect(query(of: plan.url)["SubtitleStreamIndex"] == nil)
    }
}

// MARK: - DirectStreamUrl 陷阱（核心回归）

@Suite("播放协商 · DirectStreamUrl 陷阱")
struct NegotiationDirectStreamTrapTests {

    @Test("DirectStreamUrl 存在但 SupportsDirectStream == false → 必须判为 transcode")
    func directStreamURLDoesNotImplyDirectStream() throws {
        let info = try decodePlaybackInfo(Fixtures.playbackInfoTranscode)
        let source = try #require(info.mediaSources.first)

        // ⚠️ 陷阱本身：Emby 在「必须转码」时**照样**返回 DirectStreamUrl。
        // 这两条断言是给未来的自己看的 —— 一旦有人把判定改成
        // `if source.directStreamUrl != nil { return .directStream }`，下面的
        // method == .transcode 会立刻挂掉。
        #expect(source.supportsDirectStream == false)
        #expect(source.directStreamUrl != nil)
        #expect(source.supportsDirectPlay == false)

        let plan = try makeNegotiator().negotiate(item: makeItem(), info: info)

        #expect(plan.method == .transcode)
        #expect(plan.method != .directStream)
        // 转码必须走 TranscodingUrl 的 master.m3u8。
        #expect(plan.url.path == "/emby/videos/1a2b3c4d5e6f708192a3b4c5d6e7f809/master.m3u8")
        #expect(query(of: plan.url)["TranscodeReasons"] == "VideoCodecNotSupported")
        // 原因取服务器写的 TranscodeReasons（VC-1 不在能力描述里）。
        #expect(plan.reason == .videoCodecNotSupported("vc1"))
    }

    @Test("陷阱加固：两个 URL 不同时，必须选 TranscodingUrl 而不是 DirectStreamUrl")
    func transcodeUsesTranscodingURLNotDirectStreamURL() throws {
        // 人为把两个 URL 造得**不一样**，这样「误用 DirectStreamUrl」会立刻暴露成路径不符。
        let source = MediaSource(
            id: "ms-trap",
            container: "mkv",
            runTime: Ticks(seconds: 1200),
            bitrate: 5_000_000,
            directStreamUrl: "/videos/item-1/stream?Static=true&MediaSourceId=ms-trap&api_key=key-1",
            transcodingUrl: "/videos/item-1/master.m3u8?MediaSourceId=ms-trap&api_key=key-1&VideoCodec=h264",
            mediaStreams: [videoStream("vc1"), audioStream("aac")],
            supportsDirectPlay: false,
            supportsDirectStream: false,
            supportsTranscoding: true
        )
        let info = PlaybackInfoResponse(mediaSources: [source], playSessionId: "ps-trap")

        let plan = try makeNegotiator().negotiate(item: makeItem(), info: info)

        #expect(plan.method == .transcode)
        #expect(plan.url.path == "/emby/videos/item-1/master.m3u8")
        #expect(plan.url.path != "/emby/videos/item-1/stream")
        #expect(query(of: plan.url)["Static"] == nil)
    }

    @Test("转码但缺 TranscodingUrl → 抛错，绝不拿 DirectStreamUrl 顶替")
    func missingTranscodingURLThrows() throws {
        let source = MediaSource(
            id: "ms-no-transcode-url",
            container: "mkv",
            bitrate: 5_000_000,
            directStreamUrl: "/videos/item-1/stream?Static=true&MediaSourceId=ms-no-transcode-url",
            transcodingUrl: nil,
            mediaStreams: [videoStream("vc1"), audioStream("aac")],
            supportsDirectPlay: false,
            supportsDirectStream: false,
            supportsTranscoding: true
        )
        let info = PlaybackInfoResponse(mediaSources: [source], playSessionId: "ps-1")

        #expect(throws: NegotiationError.missingPlaybackURL(method: .transcode, mediaSourceId: "ms-no-transcode-url")) {
            _ = try makeNegotiator().negotiate(item: makeItem(), info: info)
        }
    }
}

// MARK: - 直封

@Suite("播放协商 · 直封")
struct NegotiationDirectStreamTests {

    @Test("SupportsDirectStream == true 且视频可直通、容器需换 → directStream")
    func directStreamWhenContainerNeedsRemux() throws {
        // avi 不在 `.prismMacOS()` 的 DirectPlayProfiles 里，但 h264 视频流可以直通。
        let source = MediaSource(
            id: "ms-remux",
            container: "avi",
            runTime: Ticks(seconds: 3600),
            bitrate: 6_000_000,
            directStreamUrl: "/videos/item-1/stream?Static=true&MediaSourceId=ms-remux&api_key=key-1",
            transcodingUrl: "/videos/item-1/master.m3u8?MediaSourceId=ms-remux&api_key=key-1",
            mediaStreams: [videoStream("h264"), audioStream("aac")],
            supportsDirectPlay: false,
            supportsDirectStream: true,
            supportsTranscoding: true
        )
        let info = PlaybackInfoResponse(mediaSources: [source], playSessionId: "ps-remux")

        let plan = try makeNegotiator().negotiate(item: makeItem(), info: info)

        #expect(plan.method == .directStream)
        #expect(plan.reason == .containerNotSupported("avi"))
        #expect(plan.url.path == "/emby/videos/item-1/stream")
        #expect(query(of: plan.url)["Static"]?.lowercased() == "true")
        #expect(plan.method.isStreamCopy)
    }

    @Test("服务器拒绝直连但允许直封（容器本身支持）→ directStream + 回退原因")
    func directStreamFallbackReason() throws {
        let source = MediaSource(
            id: "ms-fallback",
            container: "mkv",
            bitrate: 6_000_000,
            directStreamUrl: "/videos/item-1/stream?Static=true&MediaSourceId=ms-fallback",
            transcodingUrl: "/videos/item-1/master.m3u8?MediaSourceId=ms-fallback",
            mediaStreams: [videoStream("hevc"), audioStream("eac3")],
            supportsDirectPlay: false,
            supportsDirectStream: true,
            supportsTranscoding: true
        )
        let info = PlaybackInfoResponse(mediaSources: [source], playSessionId: "ps-fallback")

        let plan = try makeNegotiator().negotiate(item: makeItem(), info: info)

        #expect(plan.method == .directStream)
        guard case .directStreamFallback = plan.reason else {
            Issue.record("期望 directStreamFallback，实际 \(plan.reason)")
            return
        }
    }

    @Test("服务器没给 DirectStreamUrl → 按官方模板自拼静态流地址")
    func directStreamWithoutServerURL() throws {
        let source = MediaSource(
            id: "ms-no-url",
            container: "avi",
            bitrate: 6_000_000,
            directStreamUrl: nil,
            transcodingUrl: "/videos/item-1/master.m3u8?MediaSourceId=ms-no-url",
            mediaStreams: [videoStream("h264"), audioStream("aac")],
            supportsDirectPlay: false,
            supportsDirectStream: true,
            supportsTranscoding: true
        )
        let info = PlaybackInfoResponse(mediaSources: [source], playSessionId: "ps-no-url")

        let plan = try makeNegotiator(headers: ["X-Emby-Token": "token-abc"]).negotiate(
            item: makeItem(),
            info: info
        )

        #expect(plan.method == .directStream)
        #expect(plan.url.path == "/emby/Videos/item-1/stream")
        let q = query(of: plan.url)
        #expect(q["Static"]?.lowercased() == "true")
        #expect(q["MediaSourceId"] == "ms-no-url")
        #expect(q["PlaySessionId"] == "ps-no-url")
        // URL 里没有 api_key 时，用鉴权头里的令牌补上。
        #expect(q["api_key"] == "token-abc")
        #expect(plan.headers["X-Emby-Token"] == "token-abc")
    }
}

// MARK: - 码率与强制转码

@Suite("播放协商 · 码率与强制转码")
struct NegotiationOverrideTests {

    @Test("码率超限：maxBitrateMbps = 10 而源是 20Mbps → transcode + bitrateExceeded")
    func bitrateLimitForcesTranscode() throws {
        let source = MediaSource(
            id: "ms-20mbps",
            container: "mkv",
            bitrate: 20_000_000,
            directStreamUrl: "/videos/item-1/stream?Static=true&MediaSourceId=ms-20mbps",
            transcodingUrl: "/videos/item-1/master.m3u8?MediaSourceId=ms-20mbps&VideoBitrate=8000000",
            mediaStreams: [videoStream("hevc"), audioStream("eac3")],
            supportsDirectPlay: true,
            supportsDirectStream: true,
            supportsTranscoding: true
        )
        let info = PlaybackInfoResponse(mediaSources: [source], playSessionId: "ps-bitrate")

        let plan = try makeNegotiator(settings: PlaybackPreferences(maxBitrateMbps: 10))
            .negotiate(item: makeItem(), info: info)

        #expect(plan.method == .transcode)
        #expect(plan.reason == .bitrateExceeded(20_000_000, limit: 10_000_000))
        #expect(plan.isTranscoding)
        // 码率超限时也要走 TranscodingUrl。
        #expect(plan.url.path == "/emby/videos/item-1/master.m3u8")
    }

    @Test("码率在限内 → 不因码率转码")
    func bitrateWithinLimitKeepsDirectPlay() throws {
        let source = MediaSource(
            id: "ms-8mbps",
            container: "mkv",
            bitrate: 8_000_000,
            directStreamUrl: "/videos/item-1/stream?Static=true&MediaSourceId=ms-8mbps",
            transcodingUrl: "/videos/item-1/master.m3u8?MediaSourceId=ms-8mbps",
            mediaStreams: [videoStream("h264"), audioStream("aac")],
            supportsDirectPlay: true,
            supportsDirectStream: true,
            supportsTranscoding: true
        )
        let info = PlaybackInfoResponse(mediaSources: [source], playSessionId: "ps-ok")

        let plan = try makeNegotiator(settings: PlaybackPreferences(maxBitrateMbps: 10))
            .negotiate(item: makeItem(), info: info)

        #expect(plan.method == .directPlay)
        #expect(plan.reason == .directPlaySupported)
    }

    @Test("forceTranscode = true → transcode + userForcedTranscode（压过服务器原因）")
    func forcedTranscodeWins() throws {
        let info = try decodePlaybackInfo(Fixtures.playbackInfoTranscode)
        let plan = try makeNegotiator(settings: PlaybackPreferences(forceTranscode: true))
            .negotiate(item: makeItem(), info: info)

        #expect(plan.method == .transcode)
        #expect(plan.reason == .userForcedTranscode)
    }

    @Test("forceTranscode 对「本来能直连」的源同样生效")
    func forcedTranscodeOnDirectPlayableSource() throws {
        let source = MediaSource(
            id: "ms-forced",
            container: "mkv",
            bitrate: 8_000_000,
            directStreamUrl: "/videos/item-1/stream?Static=true&MediaSourceId=ms-forced",
            transcodingUrl: "/videos/item-1/master.m3u8?MediaSourceId=ms-forced",
            mediaStreams: [videoStream("h264"), audioStream("aac")],
            supportsDirectPlay: true,
            supportsDirectStream: true,
            supportsTranscoding: true
        )
        let info = PlaybackInfoResponse(mediaSources: [source], playSessionId: "ps-forced")

        let plan = try makeNegotiator(settings: PlaybackPreferences(forceTranscode: true))
            .negotiate(item: makeItem(), info: info)

        #expect(plan.method == .transcode)
        #expect(plan.reason == .userForcedTranscode)
    }
}

// MARK: - 字幕烧录

@Suite("播放协商 · 字幕烧录")
struct NegotiationSubtitleTests {

    private func subtitleModePlan(
        mode: SubtitleMode,
        audioLanguage: String,
        subtitles: [MediaStream],
        interfaceLanguage: String? = "chi"
    ) throws -> PlaybackPlan {
        let source = MediaSource(
            id: "ms-subtitle-mode",
            container: "mkv",
            directStreamUrl: "/videos/item-1/stream?Static=true&MediaSourceId=ms-subtitle-mode",
            mediaStreams: [
                videoStream("h264"),
                MediaStream(index: 1, type: .audio, codec: "aac", language: audioLanguage, isDefault: true)
            ] + subtitles,
            supportsDirectPlay: true,
            supportsDirectStream: true,
            supportsTranscoding: true,
            defaultSubtitleStreamIndex: subtitles.first?.index
        )
        return try makeNegotiator(settings: PlaybackPreferences(
            interfaceLanguage: interfaceLanguage,
            subtitleMode: mode
        )).negotiate(
            item: makeItem(),
            info: PlaybackInfoResponse(mediaSources: [source], playSessionId: "ps-subtitle-mode")
        )
    }

    @Test("外语模式会按界面语言自动选择字幕，本地音轨时保持关闭")
    func foreignModeUsesInterfaceLanguage() throws {
        let chinese = srtSubtitle(index: 2)

        let foreignAudio = try subtitleModePlan(mode: .foreign, audioLanguage: "eng", subtitles: [chinese])
        let localAudio = try subtitleModePlan(mode: .foreign, audioLanguage: "chi", subtitles: [chinese])

        #expect(foreignAudio.subtitleStreamIndex == 2)
        #expect(localAudio.subtitleStreamIndex == nil)
    }

    @Test("总是 / 强制 / 从不三种自动显示模式按设置选轨")
    func subtitleModesSelectExpectedTracks() throws {
        let chinese = srtSubtitle(index: 2)
        let forced = MediaStream(
            index: 3,
            type: .subtitle,
            codec: "subrip",
            language: "eng",
            isForced: true,
            isTextSubtitleStream: true
        )
        let tracks = [chinese, forced]

        #expect(try subtitleModePlan(mode: .always, audioLanguage: "chi", subtitles: tracks).subtitleStreamIndex == 2)
        #expect(try subtitleModePlan(mode: .forced, audioLanguage: "eng", subtitles: tracks).subtitleStreamIndex == 3)
        #expect(try subtitleModePlan(mode: .never, audioLanguage: "eng", subtitles: tracks).subtitleStreamIndex == nil)
    }

    @Test("PGS 需要烧录，SRT 不需要")
    func burnInDecision() {
        let decider = SubtitleBurnInDecider()
        #expect(decider.requiresBurnIn(pgsSubtitle()))
        #expect(decider.requiresBurnIn(srtSubtitle()) == false)
        // 非字幕轨永远不烧录。
        #expect(decider.requiresBurnIn(videoStream("h264")) == false)
        #expect(decider.requiresBurnIn(audioStream("aac")) == false)
    }

    @Test("图形字幕的多种写法都能识别（含真实抓包的「PGSSUB」大写形态）")
    func imageSubtitleCodecVariants() {
        let decider = SubtitleBurnInDecider()
        for codec in ["pgssub", "PGSSUB", "PGS", "hdmv_pgs_subtitle", "dvdsub", "VOBSUB", "dvbsub", "xsub"] {
            let stream = MediaStream(index: 9, type: .subtitle, codec: codec, isTextSubtitleStream: false)
            #expect(decider.requiresBurnIn(stream), "编码 \(codec) 应判为图形字幕")
        }
        for codec in ["subrip", "srt", "ass", "ssa", "vtt", "mov_text"] {
            let stream = MediaStream(index: 9, type: .subtitle, codec: codec, isTextSubtitleStream: true)
            #expect(decider.requiresBurnIn(stream) == false, "编码 \(codec) 应判为文本字幕")
        }
    }

    @Test("服务端漏给 IsTextSubtitleStream 时，靠编码名兜底（SRT 不烧录）")
    func textCodecFallback() {
        let decider = SubtitleBurnInDecider()
        let srtWithoutFlag = MediaStream(index: 2, type: .subtitle, codec: "subrip")
        #expect(srtWithoutFlag.isTextSubtitleStream == false)
        #expect(decider.requiresBurnIn(srtWithoutFlag) == false)
    }

    @Test("burnInImageSubtitles = false → 图形字幕不烧录（用户放弃该字幕）")
    func burnInDisabled() {
        let decider = SubtitleBurnInDecider(burnInImageSubtitles: false)
        #expect(decider.requiresBurnIn(pgsSubtitle()) == false)
        // 但「是不是图形字幕」这个事实不变。
        #expect(decider.isImageSubtitle(pgsSubtitle()))
    }

    @Test("选中 PGS 字幕 → 整个播放被判为转码，且 SubtitleStreamIndex 进 URL")
    func pgsForcesTranscode() throws {
        let source = MediaSource(
            id: "ms-pgs",
            container: "mkv",
            bitrate: 8_000_000,
            directStreamUrl: "/videos/item-1/stream?Static=true&MediaSourceId=ms-pgs",
            transcodingUrl: "/videos/item-1/master.m3u8?MediaSourceId=ms-pgs&SubtitleMethod=Encode",
            mediaStreams: [videoStream("h264"), audioStream("aac"), pgsSubtitle()],
            supportsDirectPlay: true,
            supportsDirectStream: true,
            supportsTranscoding: true
        )
        let info = PlaybackInfoResponse(mediaSources: [source], playSessionId: "ps-pgs")

        let plan = try makeNegotiator().negotiate(
            item: makeItem(),
            info: info,
            subtitleStreamIndex: 3
        )

        #expect(plan.method == .transcode)
        #expect(plan.reason == .subtitleBurnedIn("English PGS"))
        #expect(plan.subtitleStreamIndex == 3)
        #expect(query(of: plan.url)["SubtitleStreamIndex"] == "3")
        // 原有参数不能丢。
        #expect(query(of: plan.url)["SubtitleMethod"] == "Encode")
    }

    @Test("关闭字幕（-1）→ 不烧录、不转码")
    func subtitlesOff() throws {
        let source = MediaSource(
            id: "ms-off",
            container: "mkv",
            bitrate: 8_000_000,
            directStreamUrl: "/videos/item-1/stream?Static=true&MediaSourceId=ms-off",
            transcodingUrl: "/videos/item-1/master.m3u8?MediaSourceId=ms-off",
            mediaStreams: [videoStream("h264"), audioStream("aac"), pgsSubtitle()],
            supportsDirectPlay: true,
            supportsDirectStream: true,
            supportsTranscoding: true
        )
        let info = PlaybackInfoResponse(mediaSources: [source], playSessionId: "ps-off")

        let plan = try makeNegotiator().negotiate(
            item: makeItem(),
            info: info,
            subtitleStreamIndex: -1
        )

        #expect(plan.method == .directPlay)
        #expect(plan.subtitleStreamIndex == nil)
    }
}

// MARK: - 续播与 URL 增补

@Suite("播放协商 · 续播与 URL 增补")
struct NegotiationURLTests {

    @Test("首选外挂字幕进入引擎请求，并保留 Emby 子路径与鉴权头继承")
    func externalSubtitleDelivery() throws {
        let subtitle = MediaStream(
            index: 5,
            type: .subtitle,
            codec: "ass",
            language: "chi",
            displayTitle: "简体中文 ASS",
            isExternal: true,
            deliveryUrl: "/Videos/item-1/item-1/Subtitles/5/0/Stream.ass",
            isTextSubtitleStream: true,
            supportsExternalStream: true
        )
        let source = MediaSource(
            id: "ms-external-subtitle",
            container: "mkv",
            directStreamUrl: "/videos/item-1/stream?Static=true&MediaSourceId=ms-external-subtitle",
            mediaStreams: [videoStream("h264"), audioStream("aac"), subtitle],
            supportsDirectPlay: true,
            supportsDirectStream: true,
            supportsTranscoding: true
        )
        let info = PlaybackInfoResponse(mediaSources: [source], playSessionId: "ps-subtitle")
        let negotiator = makeNegotiator(
            settings: PlaybackPreferences(preferredSubtitleLanguage: "chi"),
            headers: ["X-Emby-Token": "test-token"]
        )

        let plan = try negotiator.negotiate(item: makeItem(), info: info)

        #expect(plan.subtitleStreamIndex == 5)
        #expect(plan.externalSubtitles.count == 1)
        #expect(plan.externalSubtitles[0].id == "5")
        #expect(plan.externalSubtitles[0].format == .ass)
        #expect(plan.externalSubtitles[0].url.path == "/emby/Videos/item-1/item-1/Subtitles/5/0/Stream.ass")
        #expect(plan.externalSubtitles[0].httpHeaders == nil)
        #expect(plan.headers["X-Emby-Token"] == "test-token")
    }

    @Test("续播 300s → URL 含 StartTimeTicks=3000000000")
    func resumePositionInURL() throws {
        let info = try decodePlaybackInfo(Fixtures.playbackInfoTranscode)
        let start = Ticks(seconds: 300)

        let plan = try makeNegotiator().negotiate(
            item: makeItem(),
            info: info,
            startPosition: start
        )

        #expect(plan.startPosition == start)
        #expect(plan.startPosition.rawValue == 3_000_000_000)
        #expect(query(of: plan.url)["StartTimeTicks"] == "3000000000")
    }

    @Test("从头播 → 不写 StartTimeTicks（并清掉可能残留的值）")
    func zeroPositionRemovesStartTimeTicks() throws {
        let source = MediaSource(
            id: "ms-resume",
            container: "mkv",
            bitrate: 8_000_000,
            directStreamUrl: "/videos/item-1/stream?Static=true&MediaSourceId=ms-resume",
            // 服务器按上一次的续播位置算出来的 URL，带着旧偏移。
            transcodingUrl: "/videos/item-1/master.m3u8?MediaSourceId=ms-resume&StartTimeTicks=9990000000",
            mediaStreams: [videoStream("vc1"), audioStream("aac")],
            supportsDirectPlay: false,
            supportsDirectStream: false,
            supportsTranscoding: true
        )
        let info = PlaybackInfoResponse(mediaSources: [source], playSessionId: "ps-resume")

        let plan = try makeNegotiator().negotiate(item: makeItem(), info: info, startPosition: .zero)

        #expect(query(of: plan.url)["StartTimeTicks"] == nil)
    }

    @Test("URL 增补：原有参数一个不丢，新参数正确追加，api_key 不重复")
    func urlAugmentationPreservesOriginalParameters() throws {
        let transcodingURL = "/videos/item-1/master.m3u8"
            + "?DeviceId=dev-1"
            + "&MediaSourceId=ms-augment"
            + "&PlaySessionId=ps-augment"
            + "&api_key=key-original"
            + "&VideoCodec=h264"
            + "&VideoBitrate=4936000"
            + "&SegmentContainer=ts"
            + "&h264-profile=high,main"
            + "&TranscodeReasons=SubtitleCodecNotSupported"

        let source = MediaSource(
            id: "ms-augment",
            container: "mkv",
            bitrate: 8_000_000,
            directStreamUrl: "/videos/item-1/stream?Static=true&MediaSourceId=ms-augment",
            transcodingUrl: transcodingURL,
            mediaStreams: [videoStream("h264"), audioStream("ac3"), pgsSubtitle(index: 3)],
            supportsDirectPlay: true,
            supportsDirectStream: true,
            supportsTranscoding: true
        )
        let info = PlaybackInfoResponse(mediaSources: [source], playSessionId: "ps-augment")

        let plan = try makeNegotiator(headers: ["X-Emby-Token": "key-from-header"]).negotiate(
            item: makeItem(),
            info: info,
            startPosition: Ticks(seconds: 300),
            audioStreamIndex: 1,
            subtitleStreamIndex: 3
        )

        #expect(plan.method == .transcode)

        let q = query(of: plan.url)
        // ① 原有参数一个都不能丢。
        #expect(q["DeviceId"] == "dev-1")
        #expect(q["MediaSourceId"] == "ms-augment")
        #expect(q["PlaySessionId"] == "ps-augment")
        #expect(q["VideoCodec"] == "h264")
        #expect(q["VideoBitrate"] == "4936000")
        #expect(q["SegmentContainer"] == "ts")
        // 逗号分隔的值不能被转义成 %2C。
        #expect(q["h264-profile"] == "high,main")
        #expect(q["TranscodeReasons"] == "SubtitleCodecNotSupported")

        // ② 新参数正确追加。
        #expect(q["StartTimeTicks"] == "3000000000")
        #expect(q["AudioStreamIndex"] == "1")
        #expect(q["SubtitleStreamIndex"] == "3")

        // ③ 服务器算好的 api_key 不被覆盖，也不会重复出现。
        #expect(q["api_key"] == "key-original")
        #expect(queryValues(of: plan.url, name: "api_key").count == 1)
        // 路径与 baseURL 的子路径前缀都保持完整。
        #expect(plan.url.path == "/emby/videos/item-1/master.m3u8")
    }

    @Test("URL 里没有 api_key 时，用鉴权头补一个")
    func apiKeyInjectedFromHeaders() throws {
        let source = MediaSource(
            id: "ms-nokey",
            container: "mkv",
            bitrate: 8_000_000,
            directStreamUrl: "/videos/item-1/stream?Static=true&MediaSourceId=ms-nokey",
            transcodingUrl: "/videos/item-1/master.m3u8?MediaSourceId=ms-nokey",
            mediaStreams: [videoStream("vc1"), audioStream("aac")],
            supportsDirectPlay: false,
            supportsDirectStream: false,
            supportsTranscoding: true
        )
        let info = PlaybackInfoResponse(mediaSources: [source], playSessionId: "ps-nokey")

        let plan = try makeNegotiator(headers: ["X-Emby-Token": "token-xyz"]).negotiate(
            item: makeItem(),
            info: info
        )

        #expect(query(of: plan.url)["api_key"] == "token-xyz")
        #expect(plan.headers["X-Emby-Token"] == "token-xyz")
    }

    @Test("服务器给绝对 URL 时原样使用")
    func absoluteServerURLIsPreserved() throws {
        let source = MediaSource(
            id: "ms-absolute",
            container: "mkv",
            bitrate: 8_000_000,
            directStreamUrl: "https://cdn.example.net/stream?Static=true&MediaSourceId=ms-absolute",
            transcodingUrl: nil,
            mediaStreams: [videoStream("h264"), audioStream("aac")],
            supportsDirectPlay: true,
            supportsDirectStream: true,
            supportsTranscoding: true
        )
        let info = PlaybackInfoResponse(mediaSources: [source], playSessionId: "ps-absolute")

        let plan = try makeNegotiator().negotiate(item: makeItem(), info: info)

        #expect(plan.url.host == "cdn.example.net")
        #expect(plan.url.path == "/stream")
    }
}

// MARK: - 错误与选源

@Suite("播放协商 · 错误与选源")
struct NegotiationSelectionTests {

    @Test("无 MediaSources → 抛 noMediaSources，不崩")
    func emptyMediaSourcesThrows() {
        let info = PlaybackInfoResponse(mediaSources: [], playSessionId: nil)

        #expect(throws: NegotiationError.noMediaSources(itemId: "item-1")) {
            _ = try makeNegotiator().negotiate(item: makeItem(), info: info)
        }
    }

    @Test("服务器返回 ErrorCode → 抛 notPlayable")
    func serverErrorCodeThrows() throws {
        let info = try decodePlaybackInfo(Fixtures.playbackInfoNotAllowed)
        #expect(info.errorCode == .notAllowed)

        #expect(throws: NegotiationError.notPlayable(.notAllowed)) {
            _ = try makeNegotiator().negotiate(item: makeItem(), info: info)
        }
    }

    @Test("多 MediaSource：选第一个 SupportsDirectPlay 的")
    func picksFirstDirectPlayableSource() throws {
        let plain = MediaSource(
            id: "ms-plain",
            container: "mkv",
            bitrate: 8_000_000,
            directStreamUrl: "/videos/item-1/stream?Static=true&MediaSourceId=ms-plain",
            transcodingUrl: "/videos/item-1/master.m3u8?MediaSourceId=ms-plain",
            mediaStreams: [videoStream("vc1"), audioStream("ac3")],
            supportsDirectPlay: false,
            supportsDirectStream: false,
            supportsTranscoding: true
        )
        let direct = MediaSource(
            id: "ms-direct",
            container: "mkv",
            bitrate: 8_000_000,
            directStreamUrl: "/videos/item-1/stream?Static=true&MediaSourceId=ms-direct",
            transcodingUrl: "/videos/item-1/master.m3u8?MediaSourceId=ms-direct",
            mediaStreams: [videoStream("h264"), audioStream("aac")],
            supportsDirectPlay: true,
            supportsDirectStream: true,
            supportsTranscoding: true
        )
        let info = PlaybackInfoResponse(mediaSources: [plain, direct], playSessionId: "ps-multi")

        let plan = try makeNegotiator().negotiate(item: makeItem(), info: info)

        #expect(plan.mediaSourceId == "ms-direct")
        #expect(plan.method == .directPlay)
        #expect(query(of: plan.url)["MediaSourceId"] == "ms-direct")
    }

    @Test("多 MediaSource 且都不支持直连 → 取第一个")
    func fallsBackToFirstSource() throws {
        let first = MediaSource(
            id: "ms-first",
            container: "mkv",
            bitrate: 8_000_000,
            directStreamUrl: "/videos/item-1/stream?Static=true&MediaSourceId=ms-first",
            transcodingUrl: "/videos/item-1/master.m3u8?MediaSourceId=ms-first",
            mediaStreams: [videoStream("h264"), audioStream("aac")],
            supportsDirectPlay: false,
            supportsDirectStream: true,
            supportsTranscoding: true
        )
        let second = MediaSource(
            id: "ms-second",
            container: "mkv",
            bitrate: 8_000_000,
            directStreamUrl: "/videos/item-1/stream?Static=true&MediaSourceId=ms-second",
            transcodingUrl: "/videos/item-1/master.m3u8?MediaSourceId=ms-second",
            mediaStreams: [videoStream("h264"), audioStream("aac")],
            supportsDirectPlay: false,
            supportsDirectStream: true,
            supportsTranscoding: true
        )
        let info = PlaybackInfoResponse(mediaSources: [first, second], playSessionId: "ps-multi-2")

        let plan = try makeNegotiator().negotiate(item: makeItem(), info: info)

        #expect(plan.mediaSourceId == "ms-first")
    }

    @Test("preferDirectPlay = false → 直接取第一个源")
    func preferDirectPlayDisabledTakesFirst() throws {
        let plain = MediaSource(
            id: "ms-plain",
            container: "mkv",
            bitrate: 8_000_000,
            directStreamUrl: "/videos/item-1/stream?Static=true&MediaSourceId=ms-plain",
            transcodingUrl: "/videos/item-1/master.m3u8?MediaSourceId=ms-plain",
            mediaStreams: [videoStream("h264"), audioStream("aac")],
            supportsDirectPlay: false,
            supportsDirectStream: true,
            supportsTranscoding: true
        )
        let direct = MediaSource(
            id: "ms-direct",
            container: "mkv",
            bitrate: 8_000_000,
            directStreamUrl: "/videos/item-1/stream?Static=true&MediaSourceId=ms-direct",
            transcodingUrl: "/videos/item-1/master.m3u8?MediaSourceId=ms-direct",
            mediaStreams: [videoStream("h264"), audioStream("aac")],
            supportsDirectPlay: true,
            supportsDirectStream: true,
            supportsTranscoding: true
        )
        let info = PlaybackInfoResponse(mediaSources: [plain, direct], playSessionId: "ps-pref")

        let plan = try makeNegotiator(settings: PlaybackPreferences(preferDirectPlay: false))
            .negotiate(item: makeItem(), info: info)

        #expect(plan.mediaSourceId == "ms-plain")
    }
}

// MARK: - 对外契约

@Suite("播放协商 · 对外契约")
struct NegotiationContractTests {

    @Test("PlaybackMethod 映射到 Emby 的 PlayMethod 取值")
    func playMethodMapping() {
        #expect(PlaybackMethod.directPlay.embyPlayMethod == "DirectPlay")
        #expect(PlaybackMethod.directStream.embyPlayMethod == "DirectStream")
        #expect(PlaybackMethod.transcode.embyPlayMethod == "Transcode")
        #expect(PlaybackMethod.directPlay.isStreamCopy)
        #expect(PlaybackMethod.transcode.isStreamCopy == false)
    }

    @Test("Plan 是纯值类型，可跨 actor 传递（Sendable + Equatable）")
    func planIsValueType() throws {
        let info = try decodePlaybackInfo(Fixtures.playbackInfoDirectPlay)
        let plan = try makeNegotiator().negotiate(item: makeItem(), info: info)
        #expect(plan == plan)
        // 不依赖引擎：协商层只产出 URL / 方式 / 轨道。
        #expect(plan.url.isFileURL == false)
    }

    @Test("Preference 默认值符合约定")
    func preferenceDefaults() {
        let defaults = PlaybackPreferences()
        #expect(defaults.maxBitrateMbps == 0)
        #expect(defaults.preferDirectPlay)
        #expect(defaults.forceTranscode == false)
        #expect(defaults.burnInImageSubtitles)
        #expect(defaults.bitrateLimitBps == nil)
        #expect(PlaybackPreferences(maxBitrateMbps: 10).bitrateLimitBps == 10_000_000)
        // 负数按不限制处理。
        #expect(PlaybackPreferences(maxBitrateMbps: -1).bitrateLimitBps == nil)
    }

    @Test("NegotiationError 都带可读说明")
    func errorMessages() {
        #expect(NegotiationError.noMediaSources(itemId: "x").message.isEmpty == false)
        #expect(NegotiationError.notPlayable(.notAllowed).message.contains("NotAllowed"))
        #expect(NegotiationError.missingPlaybackURL(method: .transcode, mediaSourceId: "m").message.contains("transcode"))
        #expect(NegotiationError.invalidPlaybackURL("").message.isEmpty == false)
    }
}
