import Foundation
import Testing
@testable import PrismCore

/// Emby 真实返回样例（字段名与格式来自官方文档与社区抓包，见 docs/research/verified-facts.md）。
private enum Fixtures {
    /// 完整的电影条目：覆盖 RunTimeTicks / UserData / ImageTags / MediaSources / People / 日期。
    static let fullMovie = Data("""
    {
      "Name": "The Dark Knight",
      "ServerId": "37de8e11ee0748bea8d2080a13984949",
      "Id": "1861415",
      "Etag": "40ba0bf517b1c39897e54d2d1b9e5886",
      "DateCreated": "2023-01-09T20:56:49.0000000Z",
      "PremiereDate": "2008-07-18T00:00:00.0000000Z",
      "OriginalTitle": "The Dark Knight",
      "ProductionYear": 2008,
      "OfficialRating": "PG-13",
      "CommunityRating": 8.9,
      "RunTimeTicks": 91200000000,
      "Overview": "When the menace known as the Joker wreaks havoc...",
      "Type": "Movie",
      "IsFolder": false,
      "Genres": ["Action", "Crime", "Drama"],
      "ImageTags": {
        "Primary": "a07b377233352f70d88a148a2dc36404",
        "Logo": "b17b377233352f70d88a148a2dc36405",
        "Thumb": "c27b377233352f70d88a148a2dc36406"
      },
      "BackdropImageTags": ["d37b377233352f70d88a148a2dc36407", "e47b377233352f70d88a148a2dc36408"],
      "UserData": {
        "PlaybackPositionTicks": 1200000000,
        "PlayCount": 2,
        "IsFavorite": true,
        "LastPlayedDate": "2024-02-03T20:43:58.0000000Z",
        "Played": false,
        "UnplayedItemCount": null
      },
      "People": [
        {"Name": "Christian Bale", "Id": "p1", "Role": "Bruce Wayne", "Type": "Actor", "PrimaryImageTag": "t1"},
        {"Name": "Christopher Nolan", "Id": "p2", "Role": "", "Type": "Director"}
      ],
      "MediaSources": [
        {
          "Id": "ms1",
          "Name": "1080p H264",
          "Container": "mkv",
          "RunTimeTicks": 91200000000,
          "Bitrate": 8000000,
          "Size": 8589934592,
          "IsRemote": false,
          "DirectStreamUrl": "/videos/1/stream.mkv",
          "TranscodingUrl": "/videos/1/master.m3u8",
          "PlaySessionId": "ps-1",
          "SupportsDirectPlay": true,
          "SupportsDirectStream": true,
          "SupportsTranscoding": true,
          "VideoType": "VideoFile",
          "Protocol": "Http",
          "DefaultAudioStreamIndex": 1,
          "DefaultSubtitleStreamIndex": -1,
          "MediaStreams": [
            {
              "Index": 0, "Type": "Video", "Codec": "h264", "IsDefault": true, "IsExternal": false,
              "Height": 1080, "Width": 1920, "VideoRange": "HDR", "DisplayTitle": "1080p H264 SDR"
            },
            {
              "Index": 1, "Type": "Audio", "Codec": "eac3", "Language": "eng", "Channels": 6,
              "IsDefault": true, "DisplayTitle": "English EAC3 5.1 (Default)", "ChannelLayout": "5.1",
              "SampleRate": 48000, "BitRate": 640000, "Profile": "Dolby Digital Plus"
            },
            {
              "Index": 2, "Type": "Subtitle", "Codec": "subrip", "Language": "chi", "IsDefault": false,
              "IsExternal": true, "IsForced": false, "IsTextSubtitleStream": true,
              "SupportsExternalStream": true, "DeliveryUrl": "/videos/1/2/Subtitles/0/Stream.srt"
            }
          ]
        }
      ],
      "ChildCount": null
    }
    """.utf8)

    /// 最小条目：只有 Id + Name。
    static let minimal = Data(#"{"Id": "42", "Name": "Minimal"}"#.utf8)

    /// 未知 ItemType。
    static let unknownType = Data(#"{"Id": "7", "Name": "Weird", "Type": "SomeFutureType"}"#.utf8)

    /// 没有 UserData 字段。
    static let missingUserData = Data(#"{"Id": "8", "Name": "NoUserData", "Type": "Series"}"#.utf8)

    /// ImageTags 大小写混杂 + 未知 key。
    static let mixedCaseImageTags = Data("""
    {"Id": "9", "Name": "CaseTest", "Type": "Movie",
     "ImageTags": {"primary": "p1", "BACKDROP": "b1", "Logo": "l1", "thumb": "t1", "Art": "a1", "WeirdKind": "w1"}}
    """.utf8)

    /// 日期：带 7 位小数秒、带 3 位小数秒、不带时区、非法值、null。
    static let dateVariants = Data("""
    {"Id": "10", "Name": "Dates", "Type": "Movie",
     "DateCreated": "2024-04-10T04:24:53.0000000Z",
     "PremiereDate": "2024-02-10T12:34:56"}
    """.utf8)

    /// 脏数据：数组里混入坏元素、数字写成字符串、UserData 是 null。
    static let dirty = Data("""
    {"Id": 123, "Name": "Dirty", "Type": "Episode", "ProductionYear": "2021",
     "RunTimeTicks": "18000000000", "CommunityRating": "7.5",
     "Genres": "not-an-array",
     "ImageTags": null,
     "UserData": null,
     "People": [{"Name": "Good"}, "not-an-object"],
     "MediaSources": [{"Id": "ok"}, {"Id": "also-ok", "MediaStreams": [{"Index": 0}, 42]}],
     "IndexNumber": 3, "ParentIndexNumber": 1, "SeriesName": "Test Show"}
    """.utf8)

    /// 单集常见的继承图片字段：自身没有 Primary/Thumb，图片来自所属剧集。
    static let inheritedImages = Data("""
    {
      "Id": "episode-1", "Name": "第一集", "Type": "Episode",
      "ServerId": "server-1", "SeriesId": "series-1",
      "ImageTags": {}, "BackdropImageTags": [],
      "SeriesPrimaryImageTag": "series-tag",
      "PrimaryImageItemId": "series-1",
      "ParentThumbItemId": "series-1", "ParentThumbImageTag": "thumb-tag",
      "ParentBackdropItemId": "series-1",
      "ParentBackdropImageTags": ["backdrop-tag"]
    }
    """.utf8)
}

@Suite("MediaItem 解码健壮性")
struct MediaItemDecodingTests {
    @Test("完整 fixture：所有契约字段都能解出")
    func fullFixture() throws {
        let item = try JSONDecoder().decode(MediaItem.self, from: Fixtures.fullMovie)

        #expect(item.id == "1861415")
        #expect(item.name == "The Dark Knight")
        #expect(item.type == .movie)
        #expect(item.serverId == "37de8e11ee0748bea8d2080a13984949")
        #expect(item.productionYear == 2008)
        #expect(item.runTime == Ticks(seconds: 9120))
        #expect(item.runTime?.formatted == "2:32:00")
        #expect(item.officialRating == "PG-13")
        #expect(item.communityRating == 8.9)
        #expect(item.genres == ["Action", "Crime", "Drama"])
        #expect(item.originalTitle == "The Dark Knight")
        #expect(item.isFolder == false)

        // ImageTags 转成 [ImageKind: String]
        #expect(item.imageTags[.primary] == "a07b377233352f70d88a148a2dc36404")
        #expect(item.imageTags[.logo] == "b17b377233352f70d88a148a2dc36405")
        #expect(item.imageTags[.thumb] == "c27b377233352f70d88a148a2dc36406")
        #expect(item.hasPrimaryImage)
        #expect(item.backdropTags.count == 2)
        #expect(item.primaryBackdropTag == "d37b377233352f70d88a148a2dc36407")

        // UserData
        #expect(item.userData.playbackPosition == Ticks(seconds: 120))
        #expect(item.userData.playCount == 2)
        #expect(item.userData.isFavorite)
        #expect(item.userData.played == false)
        #expect(item.userData.unplayedItemCount == nil)
        #expect(item.userData.lastPlayedDate != nil)
        #expect(item.isResumable)

        // 日期
        #expect(item.dateCreated != nil)
        #expect(item.premiereDate != nil)

        // People
        #expect(item.people?.count == 2)
        #expect(item.people?.first?.name == "Christian Bale")
        #expect(item.people?.first?.role == "Bruce Wayne")
        #expect(item.people?.last?.hasImage == false)

        // MediaSources + MediaStreams
        #expect(item.mediaSources.count == 1)
        let source = try #require(item.mediaSources.first)
        #expect(source.id == "ms1")
        #expect(source.container == "mkv")
        #expect(source.runTime == Ticks(seconds: 9120))
        #expect(source.bitrate == 8_000_000)
        #expect(source.size == 8_589_934_592)
        #expect(source.isRemote == false)
        #expect(source.playSessionId == "ps-1")
        #expect(source.supportsDirectPlay)
        #expect(source.videoType == "VideoFile")
        #expect(source.defaultSubtitleStreamIndex == -1)
        #expect(source.mediaStreams.count == 3)

        let video = try #require(source.videoStream)
        #expect(video.type == .video)
        #expect(video.height == 1080)
        #expect(video.width == 1920)
        #expect(video.isHDR)

        let audio = try #require(source.defaultAudioStream)
        #expect(audio.type == .audio)
        #expect(audio.codec == "eac3")
        #expect(audio.channels == 6)
        #expect(audio.language == "eng")
        #expect(audio.channelLayout == "5.1")
        #expect(audio.sampleRate == 48_000)
        #expect(audio.profile == "Dolby Digital Plus")

        let subtitle = try #require(source.streams(ofType: .subtitle).first)
        #expect(subtitle.isExternal)
        #expect(subtitle.isTextSubtitleStream)
        #expect(subtitle.supportsExternalStream)
        #expect(subtitle.deliveryUrl == "/videos/1/2/Subtitles/0/Stream.srt")

        // 默认字幕被显式关闭（-1）
        #expect(source.defaultSubtitleStream == nil)
    }

    @Test("最小 fixture：只有 Id + Name 也能解出，其余字段取默认值")
    func minimalFixture() throws {
        let item = try JSONDecoder().decode(MediaItem.self, from: Fixtures.minimal)

        #expect(item.id == "42")
        #expect(item.name == "Minimal")
        #expect(item.type == ItemType.unknown(""))
        #expect(item.serverId == "")
        #expect(item.productionYear == nil)
        #expect(item.runTime == nil)
        #expect(item.overview == nil)
        #expect(item.genres.isEmpty)
        #expect(item.imageTags.isEmpty)
        #expect(item.backdropTags.isEmpty)
        #expect(item.mediaSources.isEmpty)
        #expect(item.people == nil)
        #expect(item.userData == .empty)
        #expect(item.isFolder == false)
        #expect(item.progress == 0)
        #expect(item.subtitle == nil)
    }

    @Test("未知 ItemType 降级保留原始字符串，不失败")
    func unknownItemType() throws {
        let item = try JSONDecoder().decode(MediaItem.self, from: Fixtures.unknownType)
        #expect(item.type.rawValue == "SomeFutureType")
        #expect(item.type == ItemType.unknown("SomeFutureType"))
        #expect(item.type.isPlayable == false)
        #expect(item.type.isContainer == false)

        // 已知类型仍然走常量比较
        #expect(ItemType("Movie") == .movie)
        #expect(ItemType("movie") == ItemType.unknown("movie")) // 类型名大小写敏感
        #expect(ItemType.movie.isPlayable)
        #expect(ItemType.series.isContainer)
    }

    @Test("UserData 缺失时给空实例")
    func missingUserData() throws {
        let item = try JSONDecoder().decode(MediaItem.self, from: Fixtures.missingUserData)
        #expect(item.userData == UserItemData.empty)
        #expect(item.userData.playbackPosition == .zero)
        #expect(item.userData.playCount == 0)
        #expect(item.userData.isFavorite == false)
        #expect(item.userData.played == false)
        #expect(item.userData.lastPlayedDate == nil)
        #expect(item.isResumable == false)
    }

    @Test("ImageTags 大小写不敏感，未知 key 保留")
    func imageTagsCaseInsensitive() throws {
        let item = try JSONDecoder().decode(MediaItem.self, from: Fixtures.mixedCaseImageTags)

        #expect(item.imageTags[.primary] == "p1")
        #expect(item.imageTags[.backdrop] == "b1")
        #expect(item.imageTags[.logo] == "l1")
        #expect(item.imageTags[.thumb] == "t1")
        #expect(item.imageTags[.art] == "a1")
        #expect(item.imageTags[ImageKind("WeirdKind")] == "w1")
        #expect(item.imageTags.count == 6)

        // 直接构造也做归一化
        #expect(ImageKind("PRIMARY") == .primary)
        #expect(ImageKind("Thumb") == .thumb)
    }

    @Test("单集继承剧集图片字段，并生成正确图片来源")
    func inheritedImageFields() throws {
        let item = try JSONDecoder().decode(MediaItem.self, from: Fixtures.inheritedImages)

        #expect(item.primaryImageTag == nil)
        #expect(item.imageSource(for: .primary) == .init(itemId: "series-1", kind: .primary, tag: "series-tag"))
        #expect(item.imageSource(for: .thumb) == .init(itemId: "series-1", kind: .thumb, tag: "thumb-tag"))
        #expect(item.imageSource(for: .backdrop) == .init(itemId: "series-1", kind: .backdrop, tag: "backdrop-tag", index: 0))
    }

    @Test("日期：带小数秒 / 不带时区都能解析")
    func dateVariants() throws {
        let item = try JSONDecoder().decode(MediaItem.self, from: Fixtures.dateVariants)
        let created = try #require(item.dateCreated)
        let premiere = try #require(item.premiereDate)

        // 2024-04-10T04:24:53Z
        #expect(created.timeIntervalSince1970 == 1_712_723_093)
        // 2024-02-10T12:34:56 按 UTC 解释
        #expect(premiere.timeIntervalSince1970 == 1_707_568_496)
    }

    @Test(
        "EmbyDateDecoding 覆盖各种真实格式",
        arguments: [
            "2024-04-10T04:24:53.0000000Z",
            "2022-08-25T22:32:16.4732395Z",
            "2022-09-11T04:02:17.365Z",
            "2024-02-10T12:34:56.0000000+00:00",
            "2024-02-10T12:34:56+08:00",
            "2024-02-10T12:34:56",
            "2024-02-10",
            "  2024-04-10T04:24:53Z  "
        ]
    )
    func embyDateFormats(string: String) {
        #expect(EmbyDateDecoding.date(from: string) != nil)
    }

    @Test(
        "非法日期返回 nil 而不是抛错",
        arguments: ["", "   ", "not-a-date", "2024-13-45T99:99:99Z", "1699999999"]
    )
    func invalidDates(string: String) {
        #expect(EmbyDateDecoding.date(from: string) == nil)
    }

    @Test("脏数据不崩：类型不符、数组混入坏元素、null 字段")
    func dirtyPayload() throws {
        let item = try JSONDecoder().decode(MediaItem.self, from: Fixtures.dirty)

        #expect(item.id == "123")            // 数字 Id 退化为空串
        #expect(item.name == "Dirty")
        #expect(item.type == .episode)
        #expect(item.productionYear == 2021) // "2021" → 2021
        #expect(item.runTime == Ticks(seconds: 1800))
        #expect(item.communityRating == 7.5)
        #expect(item.genres.isEmpty)         // 字符串不是数组 → 空
        #expect(item.imageTags.isEmpty)      // null → 空
        #expect(item.userData == .empty)     // null → 空实例
        #expect(item.people?.count == 1)     // 坏元素被丢弃
        #expect(item.people?.first?.name == "Good")
        #expect(item.mediaSources.count == 2)
        #expect(item.mediaSources[1].mediaStreams.count == 1) // 42 被丢弃
        #expect(item.subtitle == "S01E03")
    }

    @Test("编解码往返：PascalCase 字段名保持不变")
    func codableRoundTrip() throws {
        let item = try JSONDecoder().decode(MediaItem.self, from: Fixtures.fullMovie)
        let data = try JSONEncoder().encode(item)
        let reDecoded = try JSONDecoder().decode(MediaItem.self, from: data)
        #expect(reDecoded == item)

        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"RunTimeTicks\""))
        #expect(text.contains("\"ImageTags\""))
        #expect(text.contains("\"UserData\""))
        #expect(text.contains("\"MediaSources\""))
    }
}

@Suite("其它模型解码")
struct ModelDecodingTests {
    @Test("EmbyUser：IsAdministrator 藏在 Policy 里")
    func embyUserPolicy() throws {
        let json = Data("""
        {"Name": "scott", "ServerId": "be875b9574774ca58c487f1a290dff83",
         "Id": "823e15cd455744859ec898feb27bd4f0", "PrimaryImageTag": "a908",
         "HasPassword": true, "LastLoginDate": "2022-08-25T22:32:16.4732395Z",
         "DateCreated": "0001-01-01T00:00:00.0000000Z",
         "Policy": {"IsAdministrator": true, "IsDisabled": false}}
        """.utf8)
        let user = try JSONDecoder().decode(EmbyUser.self, from: json)

        #expect(user.name == "scott")
        #expect(user.id == "823e15cd455744859ec898feb27bd4f0")
        #expect(user.isAdministrator)
        #expect(user.hasPassword)
        #expect(user.hasImage)
        #expect(user.initial == "S")
        #expect(user.lastLoginDate != nil)
        #expect(user.dateCreated != nil) // .NET 零值也能解析
    }

    @Test("EmbyUser：Policy 缺失时按非管理员处理")
    func embyUserWithoutPolicy() throws {
        let json = Data(#"{"Id": "u1", "Name": "guest"}"#.utf8)
        let user = try JSONDecoder().decode(EmbyUser.self, from: json)
        #expect(user.isAdministrator == false)
        #expect(user.serverId == "")
        #expect(user.hasImage == false)
    }

    @Test("AuthSession：User 既可能是对象也可能是单元素数组")
    func authSessionToleratesBothShapes() throws {
        let objectShape = Data("""
        {"AccessToken": "SECRET-TOKEN-VALUE", "ServerId": "srv",
         "User": {"Id": "u1", "Name": "alice", "ServerId": "srv"}}
        """.utf8)
        let arrayShape = Data("""
        {"AccessToken": "SECRET-TOKEN-VALUE", "ServerId": "srv",
         "User": [{"Id": "u1", "Name": "alice", "ServerId": "srv"}]}
        """.utf8)

        let a = try JSONDecoder().decode(AuthSession.self, from: objectShape)
        let b = try JSONDecoder().decode(AuthSession.self, from: arrayShape)

        #expect(a == b)
        #expect(a.user.name == "alice")
        #expect(a.userId == "u1")
        #expect(a.serverId == "srv")
        #expect(a.accessToken == "SECRET-TOKEN-VALUE")
        #expect(a.isValid)
        #expect(a.id == "srv:u1")
        #expect(!a.redactedDescription.contains("SECRET-TOKEN-VALUE"))
    }

    @Test("AuthSession：空数组 / 缺 User 也不崩")
    func authSessionDegrades() throws {
        let json = Data(#"{"AccessToken": "tok", "User": []}"#.utf8)
        let session = try JSONDecoder().decode(AuthSession.self, from: json)
        #expect(session.user.name == "")
        #expect(session.userId == "")
        #expect(session.isValid == false)
    }

    @Test("PublicServerInfo")
    func publicServerInfo() throws {
        let json = Data("""
        {"Id": "srv1", "ServerName": "My Emby", "Version": "4.8.11.0",
         "LocalAddress": "http://192.168.1.10:8096", "WanAddress": "https://emby.example.com",
         "LocalAddresses": ["http://192.168.1.10:8096"], "RemoteAddresses": ["https://emby.example.com"]}
        """.utf8)
        let info = try JSONDecoder().decode(PublicServerInfo.self, from: json)
        #expect(info.id == "srv1")
        #expect(info.serverName == "My Emby")
        #expect(info.majorVersion == 4)
        #expect(info.localAddresses.count == 1)
        #expect(info.isLikelyJellyfin == false)
    }

    @Test("ServerConnection：URL 与端口推导")
    func serverConnection() throws {
        let url = try #require(URL(string: "https://emby.example.com"))
        let connection = ServerConnection(id: "srv1", name: "Home", baseURL: url)
        #expect(connection.isSecure)
        #expect(connection.host == "emby.example.com")
        #expect(connection.port == 443)

        let info = PublicServerInfo(id: "srv1", serverName: "My Emby", version: "4.8")
        let fromInfo = ServerConnection(info: info, baseURL: url)
        #expect(fromInfo.name == "My Emby")
        #expect(fromInfo.id == "srv1")

        // 往返
        let data = try JSONEncoder().encode(connection)
        let back = try JSONDecoder().decode(ServerConnection.self, from: data)
        #expect(back == connection)
    }

    @Test("MediaStream：Type 大小写不敏感 + Lyric")
    func streamTypeCaseInsensitive() throws {
        let json = Data("""
        [
          {"Index": 0, "Type": "subtitle", "Codec": "ass"},
          {"Index": 1, "Type": "AUDIO", "Codec": "aac"},
          {"Index": 2, "Type": "Lyric"},
          {"Index": 3, "Type": "EmbeddedImage"},
          {"Index": 4, "Type": "SomethingNew"}
        ]
        """.utf8)

        let streams = try JSONDecoder().decode([MediaStream].self, from: json)
        #expect(streams[0].type == .subtitle)
        #expect(streams[1].type == .audio)
        #expect(streams[2].type == .lyric)
        #expect(streams[3].type == .embeddedImage)
        #expect(streams[4].type == StreamType.unknown("SomethingNew"))
        #expect(streams[0].displayName == "ass")
    }
}
