import Foundation
import PrismCore

/// `/Users/{userId}/Items` 的查询参数（类型安全版）。
///
/// 参数表来源（已核实）：<https://dev.emby.media/reference/RestAPI/ItemsService/getUsersByUseridItems.html>
/// （该端点共 84 个 query 参数，这里收录客户端实际会用到的子集）。
///
/// ## 用法
///
/// ```swift
/// var query = ItemsQuery(parentId: moviesViewId, includeItemTypes: [.movie])
/// query.recursive = true
/// query.sortBy = [.sortName]
/// query.sortOrder = [.ascending]
/// query.startIndex = 0
/// query.limit = 60
///
/// let page: ItemsQueryResult = try await client.send(ItemsEndpoint(userId: userId, query: query))
/// ```
///
/// ## 三个必须记住的坑
///
/// 1. **`Fields` 不传，服务端就不返回对应字段**：`Overview` / `People` / `MediaSources` 等
///    全部为空。``fields`` 默认取 ``ItemField/defaultFields``，需要精简响应时显式改小。
/// 2. **`Genres` / `Tags` / `Studios` / `OfficialRatings` 用竖线 `|` 分隔**，其余数组参数
///    （`IncludeItemTypes` / `Years` / `SortBy`…）用逗号。本类型已按官方表区分，不要自己拼。
/// 3. **`SortBy` 与 `SortOrder` 按位置一一对应**，官方未说明 `SortOrder` 少于 `SortBy`
///    时的补位规则 —— 永远写等长（见 ``sortOrder`` 的说明）。
public struct ItemsQuery: Sendable, Hashable {
    /// 限定在某文件夹 / 视图内；省略则从根开始。
    public var parentId: String?

    /// 是否递归子文件夹。
    public var recursive: Bool?

    /// 只返回这些类型（逗号分隔）。
    public var includeItemTypes: [ItemType]

    /// 排除这些类型（逗号分隔）。
    public var excludeItemTypes: [ItemType]

    /// 额外字段（逗号分隔）。**不传就为空**，默认 ``ItemField/defaultFields``。
    public var fields: [ItemField]

    /// 排序字段（逗号分隔，可多字段）。
    public var sortBy: [ItemSortBy]

    /// 排序方向（逗号分隔）。
    ///
    /// - Important: 与 ``sortBy`` **按位置一一对应**。官方没说明项数少于 `SortBy` 时补什么，
    ///   因此 ``ItemsEndpoint`` 会把 `SortOrder` 补齐到与 `SortBy` 等长（缺的用 `Ascending`）。
    public var sortOrder: [SortOrder]

    /// 过滤条件（逗号分隔）。
    public var filters: [ItemFilter]

    /// 只看已看 / 未看。
    public var isPlayed: Bool?

    /// 只看收藏。
    public var isFavorite: Bool?

    /// 类型过滤，**竖线 `|` 分隔**。
    public var genres: [String]

    /// 年份过滤（逗号分隔）。
    public var years: [Int]

    /// 分级过滤，**竖线 `|` 分隔**。
    public var officialRatings: [String]

    /// 标签过滤，**竖线 `|` 分隔**。
    public var tags: [String]

    /// 排除标签，**竖线 `|` 分隔**。
    public var excludeTags: [String]

    /// 制片厂过滤，**竖线 `|` 分隔**。
    public var studios: [String]

    /// 制片厂 id 过滤（逗号分隔）。
    public var studioIds: [String]

    /// 按人物姓名过滤。
    public var person: String?

    /// 按人物 id 过滤（逗号分隔）。
    public var personIds: [String]

    /// 按人物类型过滤（`Actor` / `Director`…，逗号分隔）。
    public var personTypes: [String]

    /// 搜索词。
    public var searchTerm: String?

    /// 分页起点（0 基）。
    public var startIndex: Int?

    /// 每页条数。
    ///
    /// - Important: 官方未公布默认上限，实测 100–1000 不等；**永远显式传**，且建议 ≤ 200
    ///   （过大可能导致服务器超时 / 内存暴涨）。
    public var limit: Int?

    /// 是否返回图片信息。
    public var enableImages: Bool?

    /// 是否返回 `UserData`。
    public var enableUserData: Bool?

    /// 每种图片类型最多返回几个（`Backdrop` 多图时用它限流）。
    public var imageTypeLimit: Int?

    /// 只返回这些图片类型（如 `Primary` / `Backdrop` / `Thumb`）。
    public var enableImageTypes: [ImageKind]

    /// 媒体大类过滤（`Video` / `Audio` / `Photo` / `Book`）。
    public var mediaTypes: [MediaKind]

    /// 直接按 id 列表取（逗号分隔）。
    public var ids: [String]

    /// 社区评分下限。
    public var minCommunityRating: Double?

    /// 影评人评分下限。
    public var minCriticRating: Double?

    /// 只看有字幕。
    public var hasSubtitles: Bool?

    /// 只看高清。
    public var isHD: Bool?

    /// 只看未播出。
    public var isUnaired: Bool?

    /// 首播日期下限（ISO8601）。
    public var minPremiereDate: Date?

    /// 首播日期上限（ISO8601）。
    public var maxPremiereDate: Date?

    /// 是否把 boxset 内的条目折叠。
    public var groupItemsIntoCollections: Bool?

    /// 字母索引：名字以该串开头。
    public var nameStartsWith: String?

    /// 字母索引：名字排序大于等于该串。
    public var nameStartsWithOrGreater: String?

    /// 字母索引：名字小于该串。
    public var nameLessThan: String?

    /// 只看文件夹 / 只看非文件夹。
    public var isFolder: Bool?

    /// 只看缺失集（剧集场景）。
    public var isMissing: Bool?

    /// 创建一个空查询（`fields` 取 ``ItemField/defaultFields``）。
    public init() {
        self.includeItemTypes = []
        self.excludeItemTypes = []
        self.fields = ItemField.defaultFields
        self.sortBy = []
        self.sortOrder = []
        self.filters = []
        self.genres = []
        self.years = []
        self.officialRatings = []
        self.tags = []
        self.excludeTags = []
        self.studios = []
        self.studioIds = []
        self.personIds = []
        self.personTypes = []
        self.enableImageTypes = []
        self.mediaTypes = []
        self.ids = []
    }

    /// 以最常用的三个参数创建。
    ///
    /// - Parameters:
    ///   - parentId: 父级 id（媒体库 / 文件夹）。
    ///   - includeItemTypes: 只返回这些类型。
    ///   - fields: 额外字段；`nil` 时取 ``ItemField/defaultFields``。
    public init(
        parentId: String? = nil,
        includeItemTypes: [ItemType] = [],
        fields: [ItemField]? = nil
    ) {
        self.init()
        self.parentId = parentId
        self.includeItemTypes = includeItemTypes
        if let fields { self.fields = fields }
    }

    /// 把参数拼成 ``EmbyEndpoint/query`` 需要的字典。
    ///
    /// 只写入非 `nil`、非空的值；`Bool` 写成小写 `true` / `false`。
    ///
    /// - Returns: 查询参数字典。
    public func makeQuery() -> [String: String] {
        var accumulator = QueryAccumulator()
        accumulator.put("ParentId", parentId)
        accumulator.put("Recursive", recursive)
        accumulator.putList("IncludeItemTypes", includeItemTypes)
        accumulator.putList("ExcludeItemTypes", excludeItemTypes)
        accumulator.putList("Fields", fields)
        accumulator.putList("SortBy", sortBy)
        accumulator.putList("SortOrder", normalizedSortOrder)
        accumulator.putList("Filters", filters)
        accumulator.put("IsPlayed", isPlayed)
        accumulator.put("IsFavorite", isFavorite)
        accumulator.putStrings("Genres", genres, separator: "|")
        accumulator.putInts("Years", years)
        accumulator.putStrings("OfficialRatings", officialRatings, separator: "|")
        accumulator.putStrings("Tags", tags, separator: "|")
        accumulator.putStrings("ExcludeTags", excludeTags, separator: "|")
        accumulator.putStrings("Studios", studios, separator: "|")
        accumulator.putStrings("StudioIds", studioIds)
        accumulator.put("Person", person)
        accumulator.putStrings("PersonIds", personIds)
        accumulator.putStrings("PersonTypes", personTypes)
        accumulator.put("SearchTerm", searchTerm)
        accumulator.put("StartIndex", startIndex)
        accumulator.put("Limit", limit)
        accumulator.put("EnableImages", enableImages)
        accumulator.put("EnableUserData", enableUserData)
        accumulator.put("ImageTypeLimit", imageTypeLimit)
        accumulator.putList("EnableImageTypes", enableImageTypes)
        accumulator.putList("MediaTypes", mediaTypes)
        accumulator.putStrings("Ids", ids)
        accumulator.put("MinCommunityRating", minCommunityRating)
        accumulator.put("MinCriticRating", minCriticRating)
        accumulator.put("HasSubtitles", hasSubtitles)
        accumulator.put("IsHD", isHD)
        accumulator.put("IsUnaired", isUnaired)
        accumulator.put("MinPremiereDate", minPremiereDate.map(EmbyDateDecoding.string(from:)))
        accumulator.put("MaxPremiereDate", maxPremiereDate.map(EmbyDateDecoding.string(from:)))
        accumulator.put("GroupItemsIntoCollections", groupItemsIntoCollections)
        accumulator.put("NameStartsWith", nameStartsWith)
        accumulator.put("NameStartsWithOrGreater", nameStartsWithOrGreater)
        accumulator.put("NameLessThan", nameLessThan)
        accumulator.put("IsFolder", isFolder)
        accumulator.put("IsMissing", isMissing)
        return accumulator.values
    }

    /// 补齐 `SortOrder`，保证与 `SortBy` 等长（缺的用 `Ascending`）。
    ///
    /// 官方只说了「按位置一一对应」，没说项数不齐时怎么办；写等长最安全。
    public var normalizedSortOrder: [SortOrder] {
        guard sortOrder.count < sortBy.count else { return sortOrder }
        return sortOrder + Array(repeating: .ascending, count: sortBy.count - sortOrder.count)
    }

    // MARK: - 常用预设

    /// 海报墙：某媒体库内的电影，按排序名升序，只带轻量字段。
    ///
    /// - Parameters:
    ///   - parentId: 媒体库 id。
    ///   - startIndex: 分页起点。
    ///   - limit: 每页条数。
    /// - Returns: 预设好的查询。
    public static func movies(parentId: String, startIndex: Int? = nil, limit: Int? = 60) -> ItemsQuery {
        var query = ItemsQuery(
            parentId: parentId,
            includeItemTypes: [.movie],
            fields: [.primaryImageAspectRatio, .productionYear, .userData, .runTimeTicks, .officialRating]
        )
        query.recursive = true
        query.sortBy = [.sortName]
        query.sortOrder = [.ascending]
        query.startIndex = startIndex
        query.limit = limit
        return query
    }

    /// 剧集库：某媒体库内的剧，按最新入库倒序。
    ///
    /// - Parameters:
    ///   - parentId: 媒体库 id。
    ///   - startIndex: 分页起点。
    ///   - limit: 每页条数。
    /// - Returns: 预设好的查询。
    public static func series(parentId: String, startIndex: Int? = nil, limit: Int? = 60) -> ItemsQuery {
        var query = ItemsQuery(
            parentId: parentId,
            includeItemTypes: [.series],
            fields: [.primaryImageAspectRatio, .productionYear, .userData, .childCount]
        )
        query.recursive = true
        query.sortBy = [.dateCreated]
        query.sortOrder = [.descending]
        query.startIndex = startIndex
        query.limit = limit
        return query
    }

    /// 全局搜索（不限定媒体库）。
    ///
    /// - Parameter term: 搜索词。
    /// - Returns: 预设好的查询。
    public static func search(_ term: String) -> ItemsQuery {
        var query = ItemsQuery(fields: ItemField.defaultFields)
        query.searchTerm = term
        query.recursive = true
        query.limit = 60
        query.includeItemTypes = [.movie, .series, .episode, .boxSet, .person]
        return query
    }
}
