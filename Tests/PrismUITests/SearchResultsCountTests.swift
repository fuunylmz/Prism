import Testing
import EmbyAPI
import PrismCore
@testable import PrismUI

/// 搜索结果计数：不能拿本页条数冒充总数。
///
/// Emby 的搜索单页最多返回 `limit` 条，`TotalRecordCount` 才是真实命中数。
/// 丢掉它的后果是搜「沙丘」（命中上百条）时界面写「共 60 个结果」。
@Suite("SearchResults 结果计数")
struct SearchResultsCountTests {
    private func item(_ id: String, type: ItemType = .movie) -> MediaItem {
        MediaItem(id: id, name: id, type: type, serverId: "srv")
    }

    @Test("服务端总数大于本页条数时，展示为「N+」")
    func truncatedCountIsShown() {
        let results = SearchResults(
            movies: [item("a"), item("b")],
            serverTotalCount: 137
        )

        #expect(results.totalCount == 2)
        #expect(results.isTruncated)
        #expect(results.totalCountText == "137+")
    }

    @Test("本页已覆盖全部结果时，展示精确数字")
    func exactCountIsShown() {
        let results = SearchResults(
            movies: [item("a"), item("b")],
            serverTotalCount: 2
        )

        #expect(results.isTruncated == false)
        #expect(results.totalCountText == "2")
    }

    @Test("数据源没给总数时退回本页条数，不显示加号")
    func missingTotalFallsBackToPageCount() {
        let results = SearchResults(movies: [item("a")])

        #expect(results.serverTotalCount == nil)
        #expect(results.isTruncated == false)
        #expect(results.totalCountText == "1")
    }

    @Test("按原始响应分组时保留服务端总数")
    func responseTotalIsCarriedThrough() {
        let response = SearchResponse(
            items: [item("movie-1"), item("series-1", type: .series)],
            people: [],
            totalCount: 60
        )

        let results = SearchResults(response: response)

        #expect(results.serverTotalCount == 60)
        #expect(results.movies.count == 1)
        #expect(results.series.count == 1)
    }
}
