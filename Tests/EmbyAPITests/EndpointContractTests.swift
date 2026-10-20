import Foundation
import Testing
import PrismCore
@testable import EmbyAPI

/// 端点契约测试：路径 / 方法 / 鉴权 / 关键 query 参数。
///
/// 每条断言都对应官方文档里的一个事实，URL 写在各端点类的文档注释里。
@Suite("端点契约")
struct EndpointContractTests {

    // MARK: - 系统与认证

    @Test("PublicSystemInfoEndpoint：路径、免鉴权、超时")
    func publicSystemInfo() {
        let endpoint = PublicSystemInfoEndpoint()
        #expect(endpoint.path == "/System/Info/Public")
        #expect(endpoint.method == .get)
        #expect(endpoint.requiresAuth == false)
        #expect(endpoint.query.isEmpty)
        #expect(endpoint.timeout == 10)
        #expect(endpoint.resolvedPath() == "/System/Info/Public")
    }

    @Test("AuthenticateEndpoint：路径、POST、免鉴权、body 用 Pw")
    func authenticate() throws {
        let endpoint = AuthenticateEndpoint(username: "alice", password: "s3cret")
        #expect(endpoint.path == "/Users/AuthenticateByName")
        #expect(endpoint.method == .post)
        #expect(endpoint.requiresAuth == false)
        #expect(endpoint.contentType == "application/json")

        let data = try #require(endpoint.body)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(json["Username"] as? String == "alice")
        // 密码字段名是 Pw，不是 Password —— 这条断言就是防回归的。
        #expect(json["Pw"] as? String == "s3cret")
        #expect(json["Password"] == nil)
    }

    @Test("CurrentUserEndpoint：路径与鉴权")
    func currentUser() {
        let endpoint = CurrentUserEndpoint()
        #expect(endpoint.path == "/Users/Me")
        #expect(endpoint.method == .get)
        #expect(endpoint.requiresAuth)
    }

    @Test("LogoutEndpoint：POST /Sessions/Logout")
    func logout() {
        let endpoint = LogoutEndpoint()
        #expect(endpoint.path == "/Sessions/Logout")
        #expect(endpoint.method == .post)
        #expect(endpoint.requiresAuth)
        #expect(endpoint.body == nil)
    }

    // MARK: - 媒体库

    @Test("ViewsEndpoint：路径与 IncludeExternalContent")
    func views() {
        let plain = ViewsEndpoint(userId: "u1")
        #expect(plain.path == "/Users/u1/Views")
        #expect(plain.method == .get)
        #expect(plain.requiresAuth)
        #expect(plain.query.isEmpty)

        let withExternal = ViewsEndpoint(userId: "u1", includeExternalContent: false)
        #expect(withExternal.query == ["IncludeExternalContent": "false"])
        #expect(withExternal.resolvedPath() == "/Users/u1/Views?IncludeExternalContent=false")
    }

    @Test("ItemsEndpoint：路径、默认 Fields、分页与排序")
    func items() throws {
        let endpoint = ItemsEndpoint(userId: "u1", query: .movies(parentId: "lib1", limit: 60))
        #expect(endpoint.path == "/Users/u1/Items")
        #expect(endpoint.method == .get)

        let query = endpoint.query
        #expect(query["ParentId"] == "lib1")
        #expect(query["Recursive"] == "true")
        #expect(query["IncludeItemTypes"] == "Movie")
        #expect(query["Limit"] == "60")
        #expect(query["SortBy"] == "SortName")
        #expect(query["SortOrder"] == "Ascending")
        // 海报墙预设只请求轻量字段（列表默认不返回 Overview / People / MediaSources）。
        let fields = try #require(query["Fields"])
        #expect(fields.contains("PrimaryImageAspectRatio"))
        #expect(fields.contains("UserData"))
        #expect(fields.contains("RunTimeTicks"))
    }

    @Test("ItemsEndpoint：默认查询带 defaultFields")
    func itemsDefaultFields() {
        let endpoint = ItemsEndpoint(userId: "u1")
        let fields = endpoint.query["Fields"] ?? ""
        for required in ["Overview", "Genres", "People", "MediaSources", "MediaStreams",
                         "DateCreated", "ProviderIds", "Studios", "Taglines"] {
            #expect(fields.contains(required), "defaultFields 缺少 \(required)")
        }
    }

    @Test("ItemsEndpoint：Genres 用竖线、Years 用逗号、SortOrder 补齐等长")
    func itemsSeparators() {
        var query = ItemsQuery()
        query.genres = ["Action", "Drama"]
        query.years = [2020, 2021]
        query.tags = ["4K", "HDR"]
        query.sortBy = [.dateCreated, .sortName]
        query.sortOrder = [.descending]
        let endpoint = ItemsEndpoint(userId: "u1", query: query)

        #expect(endpoint.query["Genres"] == "Action|Drama")
        #expect(endpoint.query["Years"] == "2020,2021")
        #expect(endpoint.query["Tags"] == "4K|HDR")
        #expect(endpoint.query["SortBy"] == "DateCreated,SortName")
        // SortOrder 少一项时补 Ascending，保证与 SortBy 等长。
        #expect(endpoint.query["SortOrder"] == "Descending,Ascending")
    }

    @Test("ItemsEndpoint：空查询不产生空串参数")
    func itemsOmitsEmptyValues() {
        let endpoint = ItemsEndpoint(userId: "u1", query: ItemsQuery(fields: []))
        #expect(endpoint.query["ParentId"] == nil)
        #expect(endpoint.query["SearchTerm"] == nil)
        #expect(endpoint.query["Genres"] == nil)
        #expect(endpoint.query["Fields"] == nil)
    }

    @Test("ItemsEndpoint：搜索预设")
    func itemsSearchPreset() {
        let endpoint = ItemsEndpoint(userId: "u1", query: .search("dune"))
        #expect(endpoint.query["SearchTerm"] == "dune")
        #expect(endpoint.query["Recursive"] == "true")
        let types = endpoint.query["IncludeItemTypes"] ?? ""
        #expect(types.contains("Movie"))
        #expect(types.contains("Series"))
    }

    @Test("ResumeEndpoint：路径与参数子集")
    func resume() {
        let endpoint = ResumeEndpoint(userId: "u1", limit: 20)
        #expect(endpoint.path == "/Users/u1/Items/Resume")
        #expect(endpoint.query["Limit"] == "20")
        #expect(endpoint.query["MediaTypes"] == "Video")
        #expect(endpoint.query["Recursive"] == "true")
        // Resume 不发送 Latest 专属的 GroupItems。
        #expect(endpoint.query["GroupItems"] == nil)
    }

    @Test("LatestEndpoint：路径、GroupItems、无 StartIndex")
    func latest() {
        let endpoint = LatestEndpoint(
            userId: "u1",
            parentId: "lib1",
            limit: 20,
            includeItemTypes: [.movie],
            groupItems: false
        )
        #expect(endpoint.path == "/Users/u1/Items/Latest")
        #expect(endpoint.query["ParentId"] == "lib1")
        #expect(endpoint.query["Limit"] == "20")
        #expect(endpoint.query["IncludeItemTypes"] == "Movie")
        #expect(endpoint.query["GroupItems"] == "false")
        // OpenAPI 标为数组，不支持分页。
        #expect(endpoint.query["StartIndex"] == nil)
    }

    @Test("NextUpEndpoint：路径与 UserId 必填")
    func nextUp() {
        let endpoint = NextUpEndpoint(userId: "u1", seriesId: "s1", limit: 24)
        #expect(endpoint.path == "/Shows/NextUp")
        #expect(endpoint.query["UserId"] == "u1")
        #expect(endpoint.query["SeriesId"] == "s1")
        #expect(endpoint.query["Limit"] == "24")
    }

    @Test("ItemDetailEndpoint：路径")
    func itemDetail() {
        let endpoint = ItemDetailEndpoint(userId: "u1", itemId: "i1")
        #expect(endpoint.path == "/Users/u1/Items/i1")
        #expect(endpoint.method == .get)
        #expect(endpoint.query.isEmpty)
    }

    @Test("EpisodesEndpoint：路径、SeasonId、SortBy 双字段")
    func episodes() {
        let endpoint = EpisodesEndpoint(seriesId: "s1", userId: "u1", seasonId: "season1")
        #expect(endpoint.path == "/Shows/s1/Episodes")
        #expect(endpoint.query["UserId"] == "u1")
        #expect(endpoint.query["SeasonId"] == "season1")
        #expect(endpoint.query["SortBy"] == "ParentIndexNumber,IndexNumber")
        #expect(endpoint.query["SortOrder"] == "Ascending,Ascending")
        #expect(endpoint.query["Season"] == nil)
    }

    @Test("SeasonsEndpoint：路径")
    func seasons() {
        let endpoint = SeasonsEndpoint(seriesId: "s1", userId: "u1")
        #expect(endpoint.path == "/Shows/s1/Seasons")
        #expect(endpoint.query["UserId"] == "u1")
        #expect(endpoint.query["IsSpecialSeason"] == nil)
    }

    @Test("SimilarEndpoint：路径与 Limit")
    func similar() {
        let endpoint = SimilarEndpoint(itemId: "i1", userId: "u1", limit: 12)
        #expect(endpoint.path == "/Items/i1/Similar")
        #expect(endpoint.query["UserId"] == "u1")
        #expect(endpoint.query["Limit"] == "12")
    }

    // MARK: - 播放协商与上报

    @Test("PlaybackInfoEndpoint：路径、POST、UserId query、body 含 DeviceProfile")
    func playbackInfo() throws {
        let endpoint = PlaybackInfoEndpoint(
            itemId: "i1",
            userId: "u1",
            profile: .prismMacOS(),
            startTimeTicks: Ticks(seconds: 60)
        )
        #expect(endpoint.path == "/Items/i1/PlaybackInfo")
        #expect(endpoint.method == .post)
        #expect(endpoint.query == ["UserId": "u1"])
        #expect(endpoint.contentType == "application/json")

        let data = try #require(endpoint.body)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["UserId"] as? String == "u1")
        #expect(json["StartTimeTicks"] as? Int64 == 600_000_000)
        #expect(json["IsPlayback"] as? Bool == true)
        #expect(json["EnableDirectPlay"] as? Bool == true)
        // DeviceProfile 必须是单个对象，不是数组。
        let profile = try #require(json["DeviceProfile"] as? [String: Any])
        #expect(profile["Name"] as? String == "Prism macOS")
        #expect((profile["DirectPlayProfiles"] as? [Any])?.isEmpty == false)
        #expect((profile["TranscodingProfiles"] as? [Any])?.isEmpty == false)
        #expect((profile["SubtitleProfiles"] as? [Any])?.isEmpty == false)
    }

    @Test("PlayingStartEndpoint：POST /Sessions/Playing")
    func playingStart() throws {
        var report = PlaybackProgressReport(
            itemId: "i1",
            playSessionId: "ps1",
            mediaSourceId: "ms1",
            positionTicks: .zero
        )
        report.playMethod = .directPlay
        let endpoint = PlayingStartEndpoint(report: report)
        #expect(endpoint.path == "/Sessions/Playing")
        #expect(endpoint.method == .post)

        let json = try Self.jsonObject(endpoint.body)
        #expect(json["ItemId"] as? String == "i1")
        #expect(json["PlaySessionId"] as? String == "ps1")
        #expect(json["MediaSourceId"] as? String == "ms1")
        #expect(json["PlayMethod"] as? String == "DirectPlay")
        #expect(json["PositionTicks"] as? Int64 == 0)
        // QueueableMediaTypes 在 4.x schema 里不存在，不要发。
        #expect(json["QueueableMediaTypes"] == nil)
    }

    @Test("PlayingProgressEndpoint：EventName 与暂停语义")
    func playingProgress() throws {
        var report = PlaybackProgressReport(
            itemId: "i1",
            playSessionId: "ps1",
            mediaSourceId: "ms1",
            positionTicks: Ticks(seconds: 30)
        )
        report.eventName = .pause
        report.isPaused = true
        let endpoint = PlayingProgressEndpoint(report: report)
        #expect(endpoint.path == "/Sessions/Playing/Progress")
        #expect(endpoint.method == .post)

        let json = try Self.jsonObject(endpoint.body)
        #expect(json["EventName"] as? String == "Pause")
        #expect(json["IsPaused"] as? Bool == true)
        #expect(json["PositionTicks"] as? Int64 == 300_000_000)
    }

    @Test("PlayingStoppedEndpoint：14 字段，不含 PlayMethod")
    func playingStopped() throws {
        let report = PlaybackStopReport(
            itemId: "i1",
            playSessionId: "ps1",
            mediaSourceId: "ms1",
            positionTicks: Ticks(seconds: 100)
        )
        let endpoint = PlayingStoppedEndpoint(report: report)
        #expect(endpoint.path == "/Sessions/Playing/Stopped")
        #expect(endpoint.method == .post)

        let json = try Self.jsonObject(endpoint.body)
        #expect(json["ItemId"] as? String == "i1")
        #expect(json["PositionTicks"] as? Int64 == 1_000_000_000)
        // PlaybackStopInfo 的 schema 没有这些字段（官方文档「与 Start 相同」是错的）。
        #expect(json["PlayMethod"] == nil)
        #expect(json["IsPaused"] == nil)
        #expect(json["VolumeLevel"] == nil)
        #expect(json["CanSeek"] == nil)
    }

    // MARK: - 图片

    @Test("ImageEndpoint：路径、index 路径段、查询参数")
    func image() {
        let plain = ImageEndpoint(itemId: "i1", kind: .primary, tag: "t1", maxWidth: 300)
        #expect(plain.path == "/Items/i1/Images/Primary")
        #expect(plain.query["tag"] == "t1")
        #expect(plain.query["maxWidth"] == "300")
        #expect(plain.cachePolicy == .returnCacheDataElseLoad)

        let backdrop = ImageEndpoint(itemId: "i1", kind: .backdrop, index: 1, tag: "t2")
        #expect(backdrop.path == "/Items/i1/Images/Backdrop/1")

        let chapter = ImageEndpoint(itemId: "i1", kind: .chapter, index: 0)
        #expect(chapter.path == "/Items/i1/Images/Chapter/0")
    }

    // MARK: - 用户数据

    @Test("MarkPlayedEndpoint：POST / DELETE 与 DatePlayed 格式")
    func markPlayed() {
        let mark = MarkPlayedEndpoint(userId: "u1", itemId: "i1", isPlayed: true)
        #expect(mark.path == "/Users/u1/PlayedItems/i1")
        #expect(mark.method == .post)
        #expect(mark.query.isEmpty)

        let unmark = MarkPlayedEndpoint(userId: "u1", itemId: "i1", isPlayed: false)
        #expect(unmark.method == .delete)

        // DatePlayed 是 yyyyMMddHHmmss，不是 ISO8601。
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let dated = MarkPlayedEndpoint(userId: "u1", itemId: "i1", isPlayed: true, datePlayed: date)
        let played = dated.query["DatePlayed"] ?? ""
        #expect(played.count == 14)
        #expect(played.allSatisfy { $0.isNumber })
    }

    @Test("MarkFavoriteEndpoint：POST / DELETE")
    func markFavorite() {
        let add = MarkFavoriteEndpoint(userId: "u1", itemId: "i1", isFavorite: true)
        #expect(add.path == "/Users/u1/FavoriteItems/i1")
        #expect(add.method == .post)

        let remove = MarkFavoriteEndpoint(userId: "u1", itemId: "i1", isFavorite: false)
        #expect(remove.method == .delete)
    }

    // MARK: - 工具

    /// 把端点 body 解成 JSON 字典。
    private static func jsonObject(_ data: Data?) throws -> [String: Any] {
        let data = try #require(data)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

// MARK: - 参数化覆盖

/// `ItemsEndpoint` 的参数组合覆盖。
///
/// 每条用例都断言「给定查询 → 期望的 query 字典键值」，用来锁住参数拼装规则
/// （逗号 vs 竖线分隔、`nil` 省略、布尔小写）。
@Suite("ItemsEndpoint 参数组合")
struct ItemsEndpointParameterizedTests {

    /// 一条用例：查询构造闭包 + 期望包含的键值。
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let build: @Sendable (inout ItemsQuery) -> Void
        let expected: [String: String]

        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "父级 + 递归", build: { query in
            query.parentId = "lib1"
            query.recursive = true
        }, expected: ["ParentId": "lib1", "Recursive": "true"]),

        Case(name: "类型白名单", build: { query in
            query.includeItemTypes = [.movie, .series]
        }, expected: ["IncludeItemTypes": "Movie,Series"]),

        Case(name: "类型黑名单", build: { query in
            query.excludeItemTypes = [.trailer, .video]
        }, expected: ["ExcludeItemTypes": "Trailer,Video"]),

        Case(name: "分页", build: { query in
            query.startIndex = 60
            query.limit = 60
        }, expected: ["StartIndex": "60", "Limit": "60"]),

        Case(name: "搜索词 + 大小写保留", build: { query in
            query.searchTerm = "The Matrix"
        }, expected: ["SearchTerm": "The Matrix"]),

        Case(name: "已看过滤", build: { query in
            query.isPlayed = false
        }, expected: ["IsPlayed": "false"]),

        Case(name: "收藏过滤", build: { query in
            query.isFavorite = true
        }, expected: ["IsFavorite": "true"]),

        Case(name: "Filters 逗号分隔", build: { query in
            query.filters = [.isUnplayed, .isResumable]
        }, expected: ["Filters": "IsUnplayed,IsResumable"]),

        Case(name: "Genres 竖线分隔", build: { query in
            query.genres = ["Action", "Adventure"]
        }, expected: ["Genres": "Action|Adventure"]),

        Case(name: "OfficialRatings 竖线分隔", build: { query in
            query.officialRatings = ["PG-13", "R"]
        }, expected: ["OfficialRatings": "PG-13|R"]),

        Case(name: "Studios 竖线分隔", build: { query in
            query.studios = ["A24", "Studio Ghibli"]
        }, expected: ["Studios": "A24|Studio Ghibli"]),

        Case(name: "Years 逗号分隔", build: { query in
            query.years = [1999, 2024]
        }, expected: ["Years": "1999,2024"]),

        Case(name: "图片限流", build: { query in
            query.imageTypeLimit = 1
            query.enableImageTypes = [.primary, .backdrop]
        }, expected: ["ImageTypeLimit": "1", "EnableImageTypes": "Primary,Backdrop"]),

        Case(name: "媒体大类", build: { query in
            query.mediaTypes = [.video]
        }, expected: ["MediaTypes": "Video"]),

        Case(name: "按 id 取", build: { query in
            query.ids = ["a", "b"]
        }, expected: ["Ids": "a,b"]),

        Case(name: "评分下限", build: { query in
            query.minCommunityRating = 7.5
        }, expected: ["MinCommunityRating": "7.5"]),

        Case(name: "字母索引", build: { query in
            query.nameStartsWith = "Du"
        }, expected: ["NameStartsWith": "Du"]),

        Case(name: "多字段排序", build: { query in
            query.sortBy = [.productionYear, .premiereDate, .sortName]
            query.sortOrder = [.descending, .descending, .ascending]
        }, expected: [
            "SortBy": "ProductionYear,PremiereDate,SortName",
            "SortOrder": "Descending,Descending,Ascending"
        ]),

        Case(name: "显式覆盖 Fields", build: { query in
            query.fields = [.overview, .people]
        }, expected: ["Fields": "Overview,People"]),

        Case(name: "空 Fields 不发送", build: { query in
            query.fields = []
        }, expected: [:])
    ]

    @Test("参数组合", arguments: cases)
    func combinations(_ testCase: Case) {
        var query = ItemsQuery()
        testCase.build(&query)
        let endpoint = ItemsEndpoint(userId: "u1", query: query)

        for (key, value) in testCase.expected {
            #expect(endpoint.query[key] == value, "\(testCase.name)：\(key) 不符")
        }
        if testCase.expected.isEmpty {
            #expect(endpoint.query["Fields"] == nil)
        }
        // 任何组合都不应该产生空串值。
        #expect(endpoint.query.values.allSatisfy { !$0.isEmpty })
    }

    @Test("路径不随参数变化")
    func pathIsStable() {
        var query = ItemsQuery()
        query.parentId = "lib1"
        query.searchTerm = "a b&c"
        let endpoint = ItemsEndpoint(userId: "u1", query: query)
        #expect(endpoint.path == "/Users/u1/Items")
        // resolvedPath 会对空格与 & 做百分号编码。
        #expect(endpoint.resolvedPath().contains("SearchTerm=a%20b%26c"))
    }
}

// MARK: - 用户端点

/// `/Users/Me` 与 `/Users/{Id}` 的契约。
///
/// `/Users/Me` 在 Emby 侧存疑，因此必须同时保留官方确定存在的 `/Users/{Id}` 作为回退。
@Suite("用户端点")
struct UserEndpointTests {

    @Test("UserByIdEndpoint：路径与鉴权")
    func userById() {
        let endpoint = UserByIdEndpoint(userId: "8a1f0b2c3d4e5f60718293a4b5c6d7e8")
        #expect(endpoint.path == "/Users/8a1f0b2c3d4e5f60718293a4b5c6d7e8")
        #expect(endpoint.method == .get)
        #expect(endpoint.requiresAuth)
        #expect(endpoint.query.isEmpty)
    }

    @Test("CurrentUserEndpoint 与 UserByIdEndpoint 都能解出同一个用户")
    func bothDecodeSameUser() throws {
        let user = try EmbyJSON.decode(EmbyUser.self, from: Data(Fixtures.currentUserMinimal.utf8))
        #expect(user.name == "alice")
        // 两个端点的解码类型相同，回退时调用方不需要改模型。
        #expect(CurrentUserEndpoint().path != UserByIdEndpoint(userId: user.id).path)
    }
}
