import Foundation
import Testing
import PrismCore
@testable import EmbyAPI

/// `DemoEmbyClient` 的行为语义测试：分页 / 搜索 / 排序 / 筛选 / 故障注入 / 登录 / 详情 / 剧集。
@Suite("演示模式：客户端行为")
struct DemoEmbyClientTests {

    // MARK: - 分页

    @Test("分页：startIndex 0 + limit 10 返回 10 条，startIndex 10 返回接下来的 10 条")
    func pagination() async throws {
        let client = DemoEmbyClient()

        var first = ItemsQuery.movies(parentId: DemoLibrary.moviesLibraryId, startIndex: 0, limit: 10)
        first.sortBy = [.sortName]
        first.sortOrder = [.ascending]

        let page1 = try await client.items(userId: DemoLibrary.userId, query: first)
        #expect(page1.items.count == 10)
        #expect(page1.totalRecordCount == DemoLibrary.movies.count)
        #expect(page1.startIndex == 0)

        var second = first
        second.startIndex = 10
        let page2 = try await client.items(userId: DemoLibrary.userId, query: second)
        #expect(page2.items.count == 10)
        #expect(page2.startIndex == 10)

        // 两页不重叠，且拼起来与完整列表的前 20 条一致。
        let ids1 = page1.items.map { $0.id }
        let ids2 = page2.items.map { $0.id }
        #expect(Set(ids1).isDisjoint(with: Set(ids2)))

        var all = first
        all.startIndex = nil
        all.limit = nil
        let full = try await client.items(userId: DemoLibrary.userId, query: all)
        #expect(Array(full.items.prefix(20)) == page1.items + page2.items)
    }

    @Test("分页：startIndex 超出总数返回空页而不是报错")
    func paginationBeyondEnd() async throws {
        let client = DemoEmbyClient()
        var query = ItemsQuery.movies(parentId: DemoLibrary.moviesLibraryId, startIndex: 9_999, limit: 10)
        query.sortBy = [.sortName]

        let page = try await client.items(userId: DemoLibrary.userId, query: query)
        #expect(page.items.isEmpty)
        #expect(page.totalRecordCount == DemoLibrary.movies.count)
    }

    @Test("分页：最后一页不足 limit 条")
    func lastPageIsShort() async throws {
        let client = DemoEmbyClient()
        var query = ItemsQuery.movies(parentId: DemoLibrary.moviesLibraryId, startIndex: 20, limit: 10)
        query.sortBy = [.sortName]
        query.sortOrder = [.ascending]

        let page = try await client.items(userId: DemoLibrary.userId, query: query)
        #expect(page.items.count == DemoLibrary.movies.count - 20)
        #expect(page.hasMore(pageSize: 10) == false)
    }

    // MARK: - 搜索

    @Test("搜索：中文关键词命中中文标题")
    func searchChinese() async throws {
        let client = DemoEmbyClient()
        var query = ItemsQuery()
        query.searchTerm = "星"
        query.includeItemTypes = [.movie]

        let result = try await client.items(userId: DemoLibrary.userId, query: query)
        #expect(!result.items.isEmpty)
        #expect(result.items.allSatisfy { $0.type == .movie })
        #expect(result.items.contains { $0.name.contains("星") })
    }

    @Test("搜索：英文关键词命中原始标题")
    func searchEnglish() async throws {
        let client = DemoEmbyClient()
        var query = ItemsQuery()
        query.searchTerm = "interstellar"
        query.includeItemTypes = [.movie]

        let result = try await client.items(userId: DemoLibrary.userId, query: query)
        let match = try #require(result.items.first)
        #expect(match.originalTitle?.lowercased().contains("interstellar") == true)
    }

    @Test("搜索：大小写不敏感")
    func searchIsCaseInsensitive() async throws {
        let client = DemoEmbyClient()
        var lower = ItemsQuery()
        lower.searchTerm = "dune"
        var upper = ItemsQuery()
        upper.searchTerm = "DUNE"

        let a = try await client.items(userId: DemoLibrary.userId, query: lower)
        let b = try await client.items(userId: DemoLibrary.userId, query: upper)
        #expect(a.items.map { $0.id } == b.items.map { $0.id })
        #expect(!a.items.isEmpty)
    }

    @Test("搜索：演员名也能命中")
    func searchByActor() async throws {
        let client = DemoEmbyClient()
        var query = ItemsQuery()
        query.searchTerm = "梁朝伟"

        let result = try await client.items(userId: DemoLibrary.userId, query: query)
        #expect(!result.items.isEmpty)
        #expect(result.items.contains { $0.name.contains("花样年华") || $0.name.contains("无间道") })
    }

    @Test("搜索：无匹配返回空数组而不是报错")
    func searchNoMatch() async throws {
        let client = DemoEmbyClient()
        var query = ItemsQuery()
        query.searchTerm = "zzzz-不存在的关键词-zzzz"

        let result = try await client.items(userId: DemoLibrary.userId, query: query)
        #expect(result.items.isEmpty)
        #expect(result.totalRecordCount == 0)
    }

    // MARK: - 筛选

    @Test("筛选：isPlayed true 只返回已看")
    func filterPlayed() async throws {
        let client = DemoEmbyClient()
        var query = ItemsQuery.movies(parentId: DemoLibrary.moviesLibraryId)
        query.isPlayed = true

        let result = try await client.items(userId: DemoLibrary.userId, query: query)
        #expect(!result.items.isEmpty)
        #expect(result.items.allSatisfy { $0.userData.played })
        #expect(result.items.allSatisfy { $0.type == .movie })
    }

    @Test("筛选：isPlayed false 只返回未看")
    func filterUnplayed() async throws {
        let client = DemoEmbyClient()
        var query = ItemsQuery.movies(parentId: DemoLibrary.moviesLibraryId)
        query.isPlayed = false

        let result = try await client.items(userId: DemoLibrary.userId, query: query)
        #expect(!result.items.isEmpty)
        #expect(result.items.allSatisfy { !$0.userData.played })
    }

    @Test("筛选：已看 + 未看 = 全部")
    func filterPartitionsLibrary() async throws {
        let client = DemoEmbyClient()
        var played = ItemsQuery.movies(parentId: DemoLibrary.moviesLibraryId)
        played.isPlayed = true
        var unplayed = played
        unplayed.isPlayed = false

        let a = try await client.items(userId: DemoLibrary.userId, query: played)
        let b = try await client.items(userId: DemoLibrary.userId, query: unplayed)
        #expect(a.items.count + b.items.count == DemoLibrary.movies.count)
    }

    @Test("筛选：按类型标签")
    func filterByGenre() async throws {
        let client = DemoEmbyClient()
        var query = ItemsQuery.movies(parentId: DemoLibrary.moviesLibraryId)
        query.genres = ["Animation"]

        let result = try await client.items(userId: DemoLibrary.userId, query: query)
        #expect(!result.items.isEmpty)
        #expect(result.items.allSatisfy { $0.genres.contains("Animation") })
    }

    @Test("筛选：Filters=IsResumable 等价于 isResumable")
    func filterResumable() async throws {
        let client = DemoEmbyClient()
        var query = ItemsQuery()
        query.filters = [.isResumable]

        let result = try await client.items(userId: DemoLibrary.userId, query: query)
        #expect(!result.items.isEmpty)
        #expect(result.items.allSatisfy { $0.isResumable })
    }

    // MARK: - 排序

    @Test("排序：按年份降序")
    func sortByYearDescending() async throws {
        let client = DemoEmbyClient()
        var query = ItemsQuery.movies(parentId: DemoLibrary.moviesLibraryId)
        query.sortBy = [.productionYear]
        query.sortOrder = [.descending]

        let result = try await client.items(userId: DemoLibrary.userId, query: query)
        let years = result.items.compactMap(\.productionYear)
        #expect(years.count == result.items.count)
        #expect(years == years.sorted(by: >))
    }

    @Test("排序：按标题升序")
    func sortByTitleAscending() async throws {
        let client = DemoEmbyClient()
        var query = ItemsQuery.movies(parentId: DemoLibrary.moviesLibraryId)
        query.sortBy = [.sortName]
        query.sortOrder = [.ascending]

        let result = try await client.items(userId: DemoLibrary.userId, query: query)
        let names = result.items.map(\.name)
        #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    @Test("排序：SortOrder 缺项时按 Ascending 补齐")
    func sortOrderDefaultsToAscending() async throws {
        let client = DemoEmbyClient()
        var query = ItemsQuery.movies(parentId: DemoLibrary.moviesLibraryId)
        query.sortBy = [.productionYear]
        query.sortOrder = []

        let result = try await client.items(userId: DemoLibrary.userId, query: query)
        let years = result.items.compactMap(\.productionYear)
        #expect(years == years.sorted())
    }

    @Test("排序：结果可复现（同查询两次结果一致）")
    func sortIsDeterministic() async throws {
        let client = DemoEmbyClient()
        var query = ItemsQuery.movies(parentId: DemoLibrary.moviesLibraryId)
        query.sortBy = [.random]

        let a = try await client.items(userId: DemoLibrary.userId, query: query)
        let b = try await client.items(userId: DemoLibrary.userId, query: query)
        #expect(a.items.map { $0.id } == b.items.map { $0.id })
    }

    // MARK: - 空库

    @Test("空库模式：所有列表返回空数组，不抛错")
    func emptyLibraryReturnsEmptyArrays() async throws {
        let client = DemoEmbyClient(failure: .emptyLibrary)

        let views = try await client.views(userId: DemoLibrary.userId)
        #expect(views.isEmpty)

        let items = try await client.items(userId: DemoLibrary.userId, query: ItemsQuery())
        #expect(items.items.isEmpty)
        #expect(items.totalRecordCount == 0)

        let resume = try await client.resume(userId: DemoLibrary.userId)
        #expect(resume.isEmpty)

        let latest = try await client.latest(userId: DemoLibrary.userId)
        #expect(latest.isEmpty)

        let nextUp = try await client.nextUp(userId: DemoLibrary.userId)
        #expect(nextUp.isEmpty)

        let episodes = try await client.episodes(seriesId: DemoLibrary.series.first?.id ?? "x")
        #expect(episodes.isEmpty)

        let similar = try await client.similar(userId: DemoLibrary.userId, itemId: DemoLibrary.movies.first?.id ?? "x")
        #expect(similar.isEmpty)
    }

    @Test("空库模式：仍然可以登录（否则进不去空态界面）")
    func emptyLibraryStillAllowsLogin() async throws {
        let client = DemoEmbyClient(failure: .emptyLibrary)
        let session = try await client.authenticate(username: "alice", password: "whatever")
        #expect(session.isValid)
    }

    // MARK: - 延迟注入

    @Test("延迟注入：delay 100ms 时确实耗时 ≥ 100ms")
    func delayIsHonoured() async throws {
        let client = DemoEmbyClient(delay: .milliseconds(100))
        let clock = ContinuousClock()
        let start = clock.now
        _ = try await client.views(userId: DemoLibrary.userId)
        let elapsed = clock.now - start
        #expect(elapsed >= .milliseconds(100), "实际耗时 \(elapsed)")
    }

    @Test("延迟注入：无延迟时几乎立即返回")
    func noDelayIsFast() async throws {
        let client = DemoEmbyClient()
        let clock = ContinuousClock()
        let start = clock.now
        _ = try await client.views(userId: DemoLibrary.userId)
        let elapsed = clock.now - start
        #expect(elapsed < .milliseconds(100), "实际耗时 \(elapsed)")
    }

    // MARK: - 错误注入

    @Test("错误注入：.timeout 确实抛 .timeout")
    func injectTimeout() async {
        let client = DemoEmbyClient(failure: .timeout)
        await #expect(throws: EmbyError.timeout) {
            _ = try await client.views(userId: DemoLibrary.userId)
        }
        await #expect(throws: EmbyError.timeout) {
            _ = try await client.items(userId: DemoLibrary.userId, query: ItemsQuery())
        }
        await #expect(throws: EmbyError.timeout) {
            _ = try await client.authenticate(username: "alice", password: "x")
        }
    }

    @Test("错误注入：.unauthorized 抛 .unauthorized")
    func injectUnauthorized() async {
        let client = DemoEmbyClient(failure: .unauthorized)
        await #expect(throws: EmbyError.unauthorized) {
            _ = try await client.resume(userId: DemoLibrary.userId)
        }
    }

    @Test("错误注入：.serverError 抛 500")
    func injectServerError() async throws {
        let client = DemoEmbyClient(failure: .serverError)
        await #expect(throws: EmbyError.server(status: 500, message: "演示模式：模拟服务器内部错误")) {
            _ = try await client.latest(userId: DemoLibrary.userId)
        }
    }

    @Test("DemoFailure.error 映射：emptyLibrary 没有错误")
    func failureErrorMapping() {
        #expect(DemoFailure.timeout.error == .timeout)
        #expect(DemoFailure.unauthorized.error == .unauthorized)
        #expect(DemoFailure.emptyLibrary.error == nil)
        #expect(DemoFailure.emptyLibrary.isError == false)
        #expect(DemoFailure.serverError.isError)
    }

    // MARK: - 登录

    @Test("登录：空用户名抛 .unauthorized")
    func loginWithEmptyUsername() async {
        let client = DemoEmbyClient()
        await #expect(throws: EmbyError.unauthorized) {
            _ = try await client.authenticate(username: "", password: "x")
        }
        await #expect(throws: EmbyError.unauthorized) {
            _ = try await client.authenticate(username: "   ", password: "x")
        }
    }

    @Test("登录：任意用户名密码都成功，返回有效会话")
    func loginSucceeds() async throws {
        let client = DemoEmbyClient()
        let session = try await client.authenticate(username: "张三", password: "任意密码")

        #expect(session.isValid)
        #expect(session.userId == DemoLibrary.userId)
        #expect(session.serverId == DemoLibrary.serverId)
        #expect(!session.accessToken.isEmpty)
        #expect(session.user.name == "张三")
        #expect(session.createdAt != nil)
    }

    // MARK: - 详情

    @Test("详情：返回的条目含 overview / genres / mediaSources / people")
    func itemDetailIsComplete() async throws {
        let client = DemoEmbyClient()
        let movie = try #require(DemoLibrary.movies.first)

        let detail = try await client.itemDetail(userId: DemoLibrary.userId, itemId: movie.id)
        #expect(detail.id == movie.id)
        #expect((detail.overview ?? "").isEmpty == false)
        #expect(detail.genres.isEmpty == false)
        #expect(detail.mediaSources.isEmpty == false)
        #expect((detail.people ?? []).isEmpty == false)
        #expect(detail.runTime != nil)
        #expect(detail.productionYear != nil)
        #expect(detail.communityRating != nil)
        #expect(detail.officialRating != nil)
    }

    @Test("详情：未知 id 抛 .notFound")
    func itemDetailNotFound() async {
        let client = DemoEmbyClient()
        await #expect(throws: EmbyError.notFound) {
            _ = try await client.itemDetail(userId: DemoLibrary.userId, itemId: "not-a-real-id")
        }
    }

    // MARK: - 剧集

    @Test("剧集：episodes 返回的季号与集号正确")
    func episodesNumbering() async throws {
        let client = DemoEmbyClient()
        let show = try #require(DemoLibrary.series.first)

        let episodes = try await client.episodes(seriesId: show.id, userId: DemoLibrary.userId)
        #expect(!episodes.isEmpty)

        let seasons = try await client.seasons(seriesId: show.id, userId: DemoLibrary.userId)
        #expect(seasons.count >= 2)

        // 每一季的第 1 集都存在，且集号从 1 开始连续。
        for season in seasons {
            let seasonNumber = try #require(season.indexNumber)
            let inSeason = episodes
                .filter { $0.parentIndexNumber == seasonNumber }
                .sorted { ($0.indexNumber ?? 0) < ($1.indexNumber ?? 0) }
            #expect(!inSeason.isEmpty)
            #expect(inSeason.map { $0.indexNumber ?? 0 } == Array(1...inSeason.count))
            #expect(inSeason.allSatisfy { $0.seasonId == season.id })
            #expect(inSeason.allSatisfy { $0.seriesId == show.id })
            #expect(inSeason.allSatisfy { $0.seriesName == show.name })
        }
    }

    @Test("剧集：按 seasonId 过滤只返回该季")
    func episodesFilteredBySeason() async throws {
        let client = DemoEmbyClient()
        let show = try #require(DemoLibrary.series.first)
        let season = try #require(DemoLibrary.seasons(ofSeries: show.id).last)

        let episodes = try await client.episodes(
            seriesId: show.id,
            userId: DemoLibrary.userId,
            seasonId: season.id
        )
        #expect(!episodes.isEmpty)
        #expect(episodes.allSatisfy { $0.seasonId == season.id })
        #expect(episodes.allSatisfy { $0.parentIndexNumber == season.indexNumber })
    }

    // MARK: - 继续观看 / 接下来 / 最新 / 相似

    @Test("继续观看：只返回有进度且未看完的条目，按上次播放时间倒序")
    func resumeList() async throws {
        let client = DemoEmbyClient()
        let items = try await client.resume(userId: DemoLibrary.userId)
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { $0.isResumable })

        let dates = items.compactMap(\.userData.lastPlayedDate)
        #expect(dates == dates.sorted(by: >))
    }

    @Test("最新添加：按入库时间倒序")
    func latestList() async throws {
        let client = DemoEmbyClient()
        let items = try await client.latest(userId: DemoLibrary.userId, limit: 10)
        #expect(items.count == 10)

        let dates = items.compactMap(\.dateCreated)
        #expect(dates == dates.sorted(by: >))
    }

    @Test("最新添加：限定电影库时只返回电影")
    func latestScopedToMovies() async throws {
        let client = DemoEmbyClient()
        let items = try await client.latest(
            userId: DemoLibrary.userId,
            parentId: DemoLibrary.moviesLibraryId,
            limit: 50
        )
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { $0.type == .movie })
    }

    @Test("接下来：只返回已经开始看的剧的下一集")
    func nextUpList() async throws {
        let client = DemoEmbyClient()
        let items = try await client.nextUp(userId: DemoLibrary.userId)
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { $0.type == .episode })
        #expect(items.allSatisfy { !$0.userData.played })
    }

    @Test("相似：返回同类型标签的条目，且不含自己")
    func similarList() async throws {
        let client = DemoEmbyClient()
        let movie = try #require(DemoLibrary.movies.first { $0.name.contains("银翼杀手") })

        let items = try await client.similar(userId: DemoLibrary.userId, itemId: movie.id, limit: 6)
        #expect(!items.isEmpty)
        #expect(items.count <= 6)
        #expect(items.contains { $0.id == movie.id } == false)
        #expect(items.allSatisfy { !Set($0.genres).isDisjoint(with: Set(movie.genres)) })
    }

    // MARK: - 视图与浏览

    @Test("views 返回 3 个视图，viewItems 是它的扁平版")
    func viewsAndViewItems() async throws {
        let client = DemoEmbyClient()
        let views = try await client.views(userId: DemoLibrary.userId)
        let items = try await client.viewItems(userId: DemoLibrary.userId)

        #expect(views.count == 3)
        #expect(items.map { $0.id } == views.map { $0.id })
        #expect(items.allSatisfy { $0.type == .collectionFolder })
    }

    @Test("浏览合集：返回成员电影")
    func browseCollection() async throws {
        let client = DemoEmbyClient()
        let collection = try #require(DemoLibrary.collections.first)

        var query = ItemsQuery(parentId: collection.id)
        query.recursive = true
        let result = try await client.items(userId: DemoLibrary.userId, query: query)

        #expect(result.items.count == collection.childCount)
        #expect(result.items.allSatisfy { $0.type == .movie })
    }

    @Test("浏览剧：非递归返回季，递归返回集")
    func browseSeries() async throws {
        let client = DemoEmbyClient()
        let show = try #require(DemoLibrary.series.first)

        var seasonsQuery = ItemsQuery(parentId: show.id)
        seasonsQuery.recursive = false
        let seasons = try await client.items(userId: DemoLibrary.userId, query: seasonsQuery)
        #expect(seasons.items.allSatisfy { $0.type == .season })

        var episodesQuery = ItemsQuery(parentId: show.id)
        episodesQuery.recursive = true
        let episodes = try await client.items(userId: DemoLibrary.userId, query: episodesQuery)
        #expect(!episodes.items.isEmpty)
        #expect(episodes.items.allSatisfy { $0.type == .episode })
    }

    // MARK: - 图片

    @Test("图片：返回非空位图，且同一 id 结果稳定")
    func imageGeneration() async throws {
        let client = DemoEmbyClient()
        let movie = try #require(DemoLibrary.movies.first)

        let image = try await client.image(itemId: movie.id, kind: .primary, size: CGSize(width: 200, height: 300))
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)

        let again = try await client.image(itemId: movie.id, kind: .primary, size: CGSize(width: 200, height: 300))
        #expect(again.size == image.size)
    }

    @Test("图片：未知 id 也返回图片（不抛错）")
    func imageForUnknownItem() async throws {
        let client = DemoEmbyClient()
        let image = try await client.image(itemId: "unknown-item", kind: .backdrop, size: CGSize(width: 64, height: 36))
        #expect(image.size.width == 64)
    }
}
