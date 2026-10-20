import Foundation
import Testing
import PrismCore
@testable import EmbyAPI

/// DTO 解码测试：fixture 逐字段断言 + 容错用例。
///
/// 容错是本项目的硬约定：**字段缺失不抛错、未知枚举值降级、坏数组元素只丢自己**。
@Suite("DTO 解码")
struct EndpointDTOTests {

    // MARK: - 系统与认证

    @Test("PublicSystemInfo 解码")
    func publicInfo() throws {
        let info = try decode(PublicServerInfo.self, Fixtures.publicInfo)
        #expect(info.id == "6f1a2c3d4e5b6789a0b1c2d3e4f50617")
        #expect(info.serverName == "Living Room Emby")
        #expect(info.version == "4.8.11.0")
        #expect(info.majorVersion == 4)
        #expect(info.localAddress == "http://192.168.1.10:8096")
        #expect(info.wanAddress == "https://emby.example.com")
        #expect(info.localAddresses.count == 2)
        #expect(info.remoteAddresses == ["https://emby.example.com"])
    }

    @Test("AuthenticationResult：对象形态")
    func authenticateObjectShape() throws {
        let result = try decode(AuthenticationResult.self, Fixtures.authenticate)
        #expect(result.accessToken == "f3e2d1c0b9a87f6e5d4c3b2a1908f7e6")
        #expect(result.serverId == "6f1a2c3d4e5b6789a0b1c2d3e4f50617")
        #expect(result.user.name == "alice")
        #expect(result.user.id == "8a1f0b2c3d4e5f60718293a4b5c6d7e8")
        #expect(result.user.isAdministrator)
        #expect(result.user.hasPassword)
        #expect(result.user.primaryImageTag == "a1b2c3d4e5f60718293a4b5c6d7e8f90")
        #expect(result.user.lastLoginDate != nil)
        #expect(result.isValid)
        #expect(result.sessionInfo?.deviceId == "3c1b2a49-7f8e-4d5c-9a0b-1c2d3e4f5061")
        #expect(result.sessionInfo?.client == "Prism")
        #expect(result.sessionInfo?.playableMediaTypes == ["Audio", "Video"])
    }

    @Test("AuthenticationResult：数组形态（Swagger 标注的 UserDto[]）")
    func authenticateArrayShape() throws {
        let result = try decode(AuthenticationResult.self, Fixtures.authenticateArrayShape)
        #expect(result.accessToken == "f3e2d1c0b9a87f6e5d4c3b2a1908f7e6")
        #expect(result.user.name == "alice")
        #expect(result.user.id == "8a1f0b2c3d4e5f60718293a4b5c6d7e8")
        #expect(result.user.isAdministrator)
        #expect(result.sessionInfo?.deviceName == "fuunylmz的Mac Mini")
    }

    @Test("AuthenticationResult：两种形态解出同一个会话")
    func authenticateShapesAgree() throws {
        let object = try decode(AuthenticationResult.self, Fixtures.authenticate)
        let array = try decode(AuthenticationResult.self, Fixtures.authenticateArrayShape)
        #expect(object.asSession.userId == array.asSession.userId)
        #expect(object.asSession.accessToken == array.asSession.accessToken)
        #expect(object.asSession.id == array.asSession.id)
    }

    @Test("AuthenticationResult：空数组与缺失字段都不抛错")
    func authenticateDegrades() throws {
        let emptyUser = """
        { "User": [], "AccessToken": "tok" }
        """
        let result = try decode(AuthenticationResult.self, emptyUser)
        #expect(result.user.name.isEmpty)
        #expect(result.user.id.isEmpty)
        #expect(result.accessToken == "tok")
        #expect(result.sessionInfo == nil)

        let noUser = """
        { "AccessToken": "tok", "ServerId": "srv" }
        """
        let degraded = try decode(AuthenticationResult.self, noUser)
        #expect(degraded.serverId == "srv")
        #expect(degraded.user.id.isEmpty)
    }

    @Test("AuthenticationResult：最小 fixture 的 serverId 从 User 推导")
    func authenticateMinimal() throws {
        let result = try decode(AuthenticationResult.self, Fixtures.authenticateMinimal)
        #expect(result.serverId == "6f1a2c3d4e5b6789a0b1c2d3e4f50617")
        #expect(result.asSession.userId == "8a1f0b2c3d4e5f60718293a4b5c6d7e8")
        #expect(result.sessionInfo == nil)
    }

    @Test("CurrentUser 最小形态")
    func currentUserMinimal() throws {
        let user = try decode(EmbyUser.self, Fixtures.currentUserMinimal)
        #expect(user.name == "alice")
        #expect(user.id == "8a1f0b2c3d4e5f60718293a4b5c6d7e8")
        #expect(user.isAdministrator == false)
    }

    // MARK: - 媒体库

    @Test("Views：CollectionType 与 IsFolder")
    func views() throws {
        let result = try decode(ViewsQueryResult.self, Fixtures.views)
        #expect(result.totalRecordCount == 4)
        #expect(result.items.count == 4)

        let movies = try #require(result.items.first)
        #expect(movies.name == "Movies")
        #expect(movies.collectionType == .movies)
        #expect(movies.item.isFolder)
        #expect(movies.item.type == .collectionFolder)

        #expect(result.items[1].collectionType == .tvShows)
        #expect(result.items[2].collectionType == .music)
        // CollectionType 缺失时降级为 nil（混合文件夹）。
        #expect(result.items[3].collectionType == nil)
    }

    @Test("Items（电影）：5 条，含完整 UserData / ImageTags / MediaSources")
    func itemsMovies() throws {
        let result = try decode(ItemsQueryResult.self, Fixtures.itemsMovies)
        #expect(result.totalRecordCount == 128)
        #expect(result.items.count == 5)
        #expect(result.isEmpty == false)

        let bladeRunner = try #require(result.items.first)
        #expect(bladeRunner.id == "0f8d0805a66f7ed429ecd8890146c7c3")
        #expect(bladeRunner.name == "Blade Runner 2049")
        #expect(bladeRunner.type == .movie)
        #expect(bladeRunner.productionYear == 2017)
        #expect(bladeRunner.officialRating == "R")
        #expect(bladeRunner.communityRating == 8.1)
        #expect(bladeRunner.genres.contains("Science Fiction"))
        #expect(bladeRunner.runTime?.seconds == 9780)
        #expect(bladeRunner.runTime?.formatted == "2:43:00")
        #expect(bladeRunner.hasPrimaryImage)
        #expect(bladeRunner.primaryImageTag == "3a4b5c6d7e8f90a1b2c3d4e5f6071829")
        #expect(bladeRunner.logoImageTag == "9f8e7d6c5b4a39281706f5e4d3c2b1a0")
        #expect(bladeRunner.backdropTags.count == 2)
        #expect(bladeRunner.primaryBackdropTag == "4d5e6f708192a3b4c5d6e7f8091a2b3c")
        #expect(bladeRunner.dateCreated != nil)
        #expect(bladeRunner.premiereDate != nil)

        // UserData
        #expect(bladeRunner.userData.played)
        #expect(bladeRunner.userData.isFavorite)
        #expect(bladeRunner.userData.playCount == 2)
        #expect(bladeRunner.userData.playbackPosition == .zero)
        #expect(bladeRunner.userData.lastPlayedDate != nil)
        #expect(bladeRunner.progress == 0)

        // MediaSources
        let source = try #require(bladeRunner.mediaSources.first)
        #expect(source.id == "37bcb3827aeb2095f1b6293e9a189072")
        #expect(source.container == "mkv")
        #expect(source.size == 22_474_836_480)
        #expect(source.supportsDirectPlay)
        #expect(source.supportsDirectStream)
        #expect(source.supportsTranscoding)
        #expect(source.isRemote == false)
        #expect(source.runTime?.seconds == 9780)
        #expect(source.defaultAudioStreamIndex == 1)
        #expect(source.defaultSubtitleStreamIndex == -1)
        #expect(source.mediaStreams.count == 3)

        let video = try #require(source.mediaStreams.first)
        #expect(video.type == .video)
        #expect(video.codec == "hevc")
        #expect(video.height == 2160)
        #expect(video.width == 3840)
        #expect(video.videoRange == "HDR")
        #expect(video.isHDR)
        #expect(video.isDefault)

        let audio = source.mediaStreams[1]
        #expect(audio.type == .audio)
        #expect(audio.channels == 6)
        #expect(audio.channelLayout == "5.1")
        #expect(audio.sampleRate == 48_000)

        let subtitle = source.mediaStreams[2]
        #expect(subtitle.type == .subtitle)
        #expect(subtitle.isExternal)
        #expect(subtitle.isTextSubtitleStream)
        #expect(subtitle.supportsExternalStream)
        #expect(subtitle.deliveryUrl?.contains("Stream.srt") == true)
        #expect(subtitle.isDefault == false)
    }

    @Test("Items（电影）：进度与未看条目")
    func itemsMoviesProgress() throws {
        let result = try decode(ItemsQueryResult.self, Fixtures.itemsMovies)
        let arrival = result.items[1]
        #expect(arrival.name == "Arrival")
        #expect(arrival.isResumable)
        #expect(abs(arrival.progress - 0.3362) < 0.01)
        #expect(arrival.userData.played == false)

        // 没有 MediaSources 的条目应解成空数组而不是失败。
        let grandBudapest = result.items[2]
        #expect(grandBudapest.mediaSources.isEmpty)
        #expect(grandBudapest.backdropTags.isEmpty)
        #expect(grandBudapest.people == nil)
    }

    @Test("Items（剧集）：SeriesId / IndexNumber")
    func itemsEpisodes() throws {
        let result = try decode(ItemsQueryResult.self, Fixtures.itemsEpisodes)
        #expect(result.totalRecordCount == 9)
        #expect(result.items.count == 2)

        let pilot = try #require(result.items.first)
        #expect(pilot.type == .episode)
        #expect(pilot.seriesName == "Severance")
        #expect(pilot.seriesId == "6f708192a3b4c5d6e7f8091a2b3c4d5e")
        #expect(pilot.seasonId == "708192a3b4c5d6e7f8091a2b3c4d5e6f")
        #expect(pilot.indexNumber == 1)
        #expect(pilot.parentIndexNumber == 1)
        #expect(pilot.subtitle == "S01E01")
        #expect(pilot.userData.played)

        let second = result.items[1]
        #expect(second.subtitle == "S01E02")
        #expect(second.isResumable)
    }

    @Test("Resume：续播位置")
    func resume() throws {
        let result = try decode(ItemsQueryResult.self, Fixtures.resume)
        #expect(result.totalRecordCount == 2)
        let episode = try #require(result.items.first)
        #expect(episode.userData.playbackPosition.seconds == 1250)
        #expect(episode.userData.playbackPosition.formatted == "20:50")
        #expect(episode.isResumable)
    }

    @Test("NextUp")
    func nextUp() throws {
        let result = try decode(ItemsQueryResult.self, Fixtures.nextUp)
        #expect(result.items.count == 1)
        let episode = try #require(result.items.first)
        #expect(episode.seriesName == "Severance")
        #expect(episode.userData.played == false)
        #expect(episode.userData.playbackPosition == .zero)
    }

    @Test("空库")
    func emptyLibrary() throws {
        let result = try decode(ItemsQueryResult.self, Fixtures.emptyLibrary)
        #expect(result.isEmpty)
        #expect(result.items.isEmpty)
        #expect(result.totalRecordCount == 0)
        #expect(result.hasMore(pageSize: 60) == false)
    }

    // MARK: - 详情

    @Test("电影详情：People / Studios / Taglines")
    func itemDetailMovie() throws {
        let item = try decode(MediaItem.self, Fixtures.itemDetailMovie)
        #expect(item.id == "0f8d0805a66f7ed429ecd8890146c7c3")
        #expect(item.originalTitle == "Blade Runner 2049")
        #expect(item.overview?.isEmpty == false)
        #expect(item.genres.count == 3)

        let people = try #require(item.people)
        #expect(people.count == 5)
        let actor = try #require(people.first)
        #expect(actor.name == "Ryan Gosling")
        #expect(actor.role == "K")
        #expect(actor.type == "Actor")
        #expect(actor.hasImage)
        #expect(actor.displayName == "K · Ryan Gosling")

        let director = try #require(people.first { $0.type == "Director" })
        #expect(director.name == "Denis Villeneuve")
        #expect(director.role == nil)
        #expect(director.displayName == "Denis Villeneuve")
        #expect(director.hasImage == false)

        #expect(item.mediaSources.count == 1)
        #expect(item.userData.isFavorite)
    }

    @Test("剧集详情：ChildCount / UnplayedItemCount")
    func itemDetailSeries() throws {
        let item = try decode(MediaItem.self, Fixtures.itemDetailSeries)
        #expect(item.type == .series)
        #expect(item.isFolder)
        #expect(item.childCount == 9)
        #expect(item.userData.unplayedItemCount == 8)
        #expect(item.people?.count == 3)
        #expect(item.officialRating == "TV-MA")
    }

    @Test("集列表")
    func episodes() throws {
        let result = try decode(ItemsQueryResult.self, Fixtures.episodes)
        #expect(result.totalRecordCount == 3)
        #expect(result.items.map(\.indexNumber) == [1, 2, 3])
        #expect(result.items.allSatisfy { $0.parentIndexNumber == 1 })
    }

    // MARK: - 播放协商

    @Test("PlaybackInfo：直连")
    func playbackInfoDirectPlay() throws {
        let response = try decode(PlaybackInfoResponse.self, Fixtures.playbackInfoDirectPlay)
        #expect(response.isPlayable)
        #expect(response.errorCode == nil)
        #expect(response.playSessionId == "e643532a23ca4a60b2c70d4210c018a9")

        let source = try #require(response.primarySource)
        #expect(source.supportsDirectPlay)
        #expect(source.supportsDirectStream)
        #expect(source.directStreamUrl?.contains("Static=true") == true)
        #expect(source.transcodingUrl == nil)
        #expect(source.mediaStreams.count == 3)
    }

    @Test("PlaybackInfo：转码时 DirectStreamUrl 仍存在（不能当直封标志）")
    func playbackInfoTranscode() throws {
        let response = try decode(PlaybackInfoResponse.self, Fixtures.playbackInfoTranscode)
        let source = try #require(response.primarySource)
        #expect(source.supportsDirectPlay == false)
        #expect(source.supportsDirectStream == false)
        #expect(source.supportsTranscoding)
        // 关键：能力标志为 false，但 DirectStreamUrl 依旧有值 ——
        // 所以判定直封只能看 SupportsDirectStream。
        #expect(source.directStreamUrl != nil)
        #expect(source.directStreamUrl == source.transcodingUrl)
        #expect(source.transcodingUrl?.contains("TranscodeReasons=") == true)
        #expect(source.playSessionId == nil)
        #expect(response.playSessionId == "7c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f")
    }

    @Test("PlaybackInfo：错误码")
    func playbackInfoError() throws {
        let response = try decode(PlaybackInfoResponse.self, Fixtures.playbackInfoNotAllowed)
        #expect(response.isPlayable == false)
        #expect(response.mediaSources.isEmpty)
        #expect(response.errorCode == .notAllowed)
        #expect(response.isRateLimited == false)
        #expect(response.playSessionId == nil)
    }

    @Test("PlaybackInfo：未知错误码降级不抛错")
    func playbackInfoUnknownError() throws {
        let json = """
        { "MediaSources": [], "ErrorCode": "CosmicRays" }
        """
        let response = try decode(PlaybackInfoResponse.self, json)
        #expect(response.errorCode?.rawValue == "CosmicRays")
        #expect(response.isPlayable == false)
    }

    // MARK: - 容错

    @Test("最小条目：缺 UserData / ImageTags 不抛错")
    func minimalItem() throws {
        let item = try decode(MediaItem.self, Fixtures.minimalItem)
        #expect(item.name == "Minimal")
        #expect(item.type == .movie)
        #expect(item.userData == .empty)
        #expect(item.imageTags.isEmpty)
        #expect(item.mediaSources.isEmpty)
        #expect(item.people == nil)
        #expect(item.serverId.isEmpty)
        #expect(item.runTime == nil)
    }

    @Test("未知枚举值与脏数据降级")
    func unknownEnums() throws {
        let item = try decode(MediaItem.self, Fixtures.itemWithUnknownEnums)
        // 未知 Type 保留原字符串，不失败。
        #expect(item.type.rawValue == "HolographicNovel")
        #expect(item.type.isPlayable == false)
        // 数字字符串的 ProductionYear / RunTimeTicks 被宽松解析。
        #expect(item.productionYear == 2024)
        #expect(item.runTime?.seconds == 720)
        // null 数组退化为空数组。
        #expect(item.genres.isEmpty)
        #expect(item.backdropTags.isEmpty)
        // 空 tag 被丢弃，未知 key 原样保留。
        #expect(item.imageTags[.primary] == nil)
        #expect(item.imageTags[ImageKind("CustomArt")] == "abc123")
        // UserData 缺失 → empty。
        #expect(item.userData == .empty)
        // 未知流类型保留原字符串。
        let stream = try #require(item.mediaSources.first?.mediaStreams.first)
        #expect(stream.type.rawValue == "Brainwave")
        #expect(stream.index == 0)
    }

    @Test("QueryResult：缺 TotalRecordCount 时退化为条数")
    func queryResultWithoutTotal() throws {
        let result = try decode(ItemsQueryResult.self, Fixtures.queryResultWithoutTotal)
        #expect(result.items.count == 1)
        #expect(result.totalRecordCount == 1)
        #expect(result.startIndex == nil)
    }

    @Test("QueryResult：坏元素只丢自己")
    func queryResultLossyElements() throws {
        let json = """
        {
          "Items": [
            { "Id": "a", "Name": "Good", "Type": "Movie" },
            "not-an-object",
            { "Id": "b", "Name": "Also Good", "Type": "Episode" }
          ],
          "TotalRecordCount": 2
        }
        """
        let result = try decode(ItemsQueryResult.self, json)
        #expect(result.items.count == 2)
        #expect(result.items.map(\.name) == ["Good", "Also Good"])
    }

    @Test("QueryResult：hasMore 用过滤后总数判断")
    func queryResultHasMore() throws {
        let items = try decode(ItemsQueryResult.self, Fixtures.itemsMovies).items

        let firstPage = ItemsQueryResult(items: items, totalRecordCount: 128, startIndex: 0)
        #expect(firstPage.hasMore(pageSize: 60))

        let lastPage = ItemsQueryResult(items: items, totalRecordCount: 128, startIndex: 120)
        #expect(lastPage.hasMore(pageSize: 60) == false)

        // 空页永远没有下一页（即使总数还有）。
        let emptyPage = ItemsQueryResult(items: [], totalRecordCount: 128, startIndex: 200)
        #expect(emptyPage.hasMore(pageSize: 60) == false)
    }

    // MARK: - 请求体 DTO

    @Test("PlaybackProgressReport：最小形态只写 ItemId")
    func playbackReportMinimal() throws {
        let report = PlaybackProgressReport(itemId: "i1")
        let data = try EmbyJSON.encode(report)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["ItemId"] as? String == "i1")
        #expect(json.keys.count == 1)
    }

    @Test("PlaybackProgressReport：往返编解码")
    func playbackReportRoundTrip() throws {
        var report = PlaybackProgressReport(
            itemId: "i1",
            playSessionId: "ps1",
            mediaSourceId: "ms1",
            positionTicks: Ticks(seconds: 42)
        )
        report.playMethod = .transcode
        report.eventName = .timeUpdate
        report.isPaused = false
        report.isMuted = true
        report.volumeLevel = 80
        report.canSeek = true
        report.audioStreamIndex = 1
        report.subtitleStreamIndex = -1
        report.playbackRate = 1.0
        report.repeatMode = .repeatNone
        report.shuffle = false

        let data = try EmbyJSON.encode(report)
        let decoded = try EmbyJSON.decode(PlaybackProgressReport.self, from: data)
        #expect(decoded == report)
    }

    @Test("DeviceProfile：往返编解码，nil 字段不写出")
    func deviceProfileRoundTrip() throws {
        let profile = DeviceProfile.prismMacOS(maxStreamingBitrate: 8_000_000)
        let data = try EmbyJSON.encode(profile)
        let decoded = try EmbyJSON.decode(DeviceProfile.self, from: data)

        #expect(decoded.name == "Prism macOS")
        #expect(decoded.maxStreamingBitrate == 8_000_000)
        #expect(decoded.directPlayProfiles.count == profile.directPlayProfiles.count)
        #expect(decoded.transcodingProfiles.count == profile.transcodingProfiles.count)
        #expect(decoded.subtitleProfiles.count == profile.subtitleProfiles.count)

        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // 空数组不写出。
        #expect(json["ContainerProfiles"] == nil)
        // MaxStaticMusicBitrate 为 nil，不写出。
        #expect(json["MaxStaticMusicBitrate"] == nil)

        let subtitle = try #require(decoded.subtitleProfiles.first)
        #expect(subtitle.format == "vtt")
        #expect(subtitle.method == .external)
        // 图形字幕必须烧录。
        let pgs = try #require(decoded.subtitleProfiles.first { $0.format == "pgssub" })
        #expect(pgs.method == .encode)
    }

    @Test("DeviceProfile：未知枚举值降级")
    func deviceProfileUnknownEnum() throws {
        let json = """
        {
          "Name": "Odd",
          "TranscodingProfiles": [
            { "Container": "ts", "Type": "Hologram", "Protocol": "quantum" }
          ],
          "SubtitleProfiles": [
            { "Format": "vtt", "Method": "Telepathy" }
          ]
        }
        """
        let profile = try decode(DeviceProfile.self, json)
        #expect(profile.transcodingProfiles.first?.type?.rawValue == "Hologram")
        #expect(profile.transcodingProfiles.first?.protocolName == "quantum")
        #expect(profile.subtitleProfiles.first?.method?.rawValue == "Telepathy")
        #expect(profile.directPlayProfiles.isEmpty)
    }

    @Test("PlaybackInfoRequest：DeviceProfile 兼容数组形态解码")
    func playbackInfoRequestArrayShape() throws {
        let json = """
        {
          "UserId": "u1",
          "DeviceProfile": [ { "Name": "Array Shape" } ]
        }
        """
        let request = try decode(PlaybackInfoRequest.self, json)
        #expect(request.userId == "u1")
        #expect(request.deviceProfile?.name == "Array Shape")
    }

    // MARK: - 工具

    /// 用与 ``EmbyJSON`` 相同的解码器解一个 fixture。
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try EmbyJSON.decode(type, from: Data(json.utf8))
    }
}
