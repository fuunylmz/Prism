import Foundation
import PrismCore

// MARK: - 媒体库入口

/// `GET /Users/{userId}/Views` —— 顶层媒体库列表（首页「我的媒体」）。
///
/// 官方文档：<https://dev.emby.media/reference/RestAPI/UserViewsService/getUsersByUseridViews.html>
///
/// 返回 ``ViewsQueryResult``（`QueryResult<MediaView>`），其中 `CollectionType` 决定用哪种 UI
/// 呈现（`movies` / `tvshows` / `music`…，见 ``LibraryType``）。
///
/// ```json
/// { "Items": [ { "Name": "Movies", "Id": "…", "CollectionType": "movies",
///                "Type": "CollectionFolder", "IsFolder": true } ],
///   "TotalRecordCount": 1 }
/// ```
public struct ViewsEndpoint: EmbyEndpoint {
    /// 用户 id。
    public let userId: String

    /// 是否包含 channels / 直播电视等外部视图；`nil` 表示用服务端默认值。
    public let includeExternalContent: Bool?

    /// 以用户 id 创建。
    ///
    /// - Parameters:
    ///   - userId: 用户 id。
    ///   - includeExternalContent: 是否包含外部视图。
    public init(userId: String, includeExternalContent: Bool? = nil) {
        self.userId = userId
        self.includeExternalContent = includeExternalContent
    }

    /// `/Users/{userId}/Views`。
    public var path: String { "/Users/\(userId)/Views" }

    /// `IncludeExternalContent`。
    public var query: [String: String] {
        var accumulator = QueryAccumulator()
        accumulator.put("IncludeExternalContent", includeExternalContent)
        return accumulator.values
    }
}

// MARK: - 列表查询（核心端点）

/// `GET /Users/{userId}/Items` —— 浏览 / 搜索 / 筛选 / 分页，整个客户端最核心的端点。
///
/// 官方文档：<https://dev.emby.media/reference/RestAPI/ItemsService/getUsersByUseridItems.html>
/// （84 个 query 参数；本客户端用到的子集见 ``ItemsQuery``）
///
/// 返回 ``ItemsQueryResult``（`QueryResult<MediaItem>`）。`TotalRecordCount` 是**过滤后总数**，
/// 不是本页条数。
///
/// ```swift
/// let page: ItemsQueryResult = try await client.send(
///     ItemsEndpoint(userId: userId, query: .movies(parentId: libraryId))
/// )
/// ```
public struct ItemsEndpoint: EmbyEndpoint {
    /// 用户 id。
    public let userId: String

    /// 查询参数。
    public let itemsQuery: ItemsQuery

    /// 以用户 id 与查询创建。
    ///
    /// - Parameters:
    ///   - userId: 用户 id。
    ///   - query: 查询参数；默认空查询（`fields` 为 ``ItemField/defaultFields``）。
    public init(userId: String, query: ItemsQuery = ItemsQuery()) {
        self.userId = userId
        self.itemsQuery = query
    }

    /// 以「父级 + 类型」快速创建。
    ///
    /// - Parameters:
    ///   - userId: 用户 id。
    ///   - parentId: 父级 id。
    ///   - includeItemTypes: 只返回这些类型。
    public init(userId: String, parentId: String?, includeItemTypes: [ItemType] = []) {
        self.init(
            userId: userId,
            query: ItemsQuery(parentId: parentId, includeItemTypes: includeItemTypes)
        )
    }

    /// `/Users/{userId}/Items`。
    public var path: String { "/Users/\(userId)/Items" }

    /// 全部查询参数（由 ``ItemsQuery`` 拼装）。
    public var query: [String: String] {
        itemsQuery.makeQuery()
    }
}

// MARK: - 继续观看

/// `GET /Users/{userId}/Items/Resume` —— 「继续观看」。
///
/// 官方文档：<https://dev.emby.media/reference/RestAPI/ItemsService/getUsersByUseridItemsResume.html>
///
/// 返回 ``ItemsQueryResult``，按 `UserData.LastPlayedDate` 倒序。每项
/// `UserData.PlaybackPositionTicks` 即续播点。
///
/// - Note: 只返回「有播放进度但未完成」的条目；接近结尾时 Emby 会自动标记为已看并移出
///   Resume（具体阈值官方未说明）。
///
/// - Note: 本端点只发送官方参数表中的子集（`ParentId` / `Recursive` / `Fields` /
///   `IncludeItemTypes` / `ExcludeItemTypes` / `Filters` / `MediaTypes` / `Limit` /
///   `StartIndex` / `EnableImages` / `EnableUserData` / `ImageTypeLimit` / `EnableImageTypes`），
///   其余 ``ItemsQuery`` 字段会被忽略。
public struct ResumeEndpoint: EmbyEndpoint {
    /// 用户 id。
    public let userId: String

    /// 查询参数（只使用其中的一部分，见类型说明）。
    public let itemsQuery: ItemsQuery

    /// 以用户 id 与查询创建。
    ///
    /// - Parameters:
    ///   - userId: 用户 id。
    ///   - query: 查询参数。
    public init(userId: String, query: ItemsQuery = ItemsQuery()) {
        self.userId = userId
        self.itemsQuery = query
    }

    /// 以「条数 + 字段」快速创建。
    ///
    /// - Parameters:
    ///   - userId: 用户 id。
    ///   - limit: 条数。
    public init(userId: String, limit: Int) {
        var query = ItemsQuery(
            fields: [.primaryImageAspectRatio, .productionYear, .userData, .runTimeTicks]
        )
        query.limit = limit
        query.mediaTypes = [.video]
        query.recursive = true
        self.init(userId: userId, query: query)
    }

    /// `/Users/{userId}/Items/Resume`。
    public var path: String { "/Users/\(userId)/Items/Resume" }

    /// 查询参数。
    public var query: [String: String] {
        var accumulator = QueryAccumulator()
        accumulator.put("ParentId", itemsQuery.parentId)
        accumulator.put("Recursive", itemsQuery.recursive)
        accumulator.putList("Fields", itemsQuery.fields)
        accumulator.putList("IncludeItemTypes", itemsQuery.includeItemTypes)
        accumulator.putList("ExcludeItemTypes", itemsQuery.excludeItemTypes)
        accumulator.putList("Filters", itemsQuery.filters)
        accumulator.putList("MediaTypes", itemsQuery.mediaTypes)
        accumulator.put("Limit", itemsQuery.limit)
        accumulator.put("StartIndex", itemsQuery.startIndex)
        accumulator.put("EnableImages", itemsQuery.enableImages)
        accumulator.put("EnableUserData", itemsQuery.enableUserData)
        accumulator.put("ImageTypeLimit", itemsQuery.imageTypeLimit)
        accumulator.putList("EnableImageTypes", itemsQuery.enableImageTypes)
        return accumulator.values
    }
}

// MARK: - 最新添加

/// `GET /Users/{userId}/Items/Latest` —— 「最新添加」。
///
/// 官方文档：<https://dev.emby.media/reference/RestAPI/UserLibraryService/getUsersByUseridItemsLatest.html>
/// 语义说明：<https://dev.emby.media/doc/restapi/Latest-Items.html>
///
/// ## ⚠️ 返回类型不是 `QueryResult`
///
/// OpenAPI 把该端点标为 `array`（直接是 `BaseItemDto[]`），**没有 `TotalRecordCount`**：
///
/// ```swift
/// let items: [MediaItem] = try await client.send(LatestEndpoint(userId: userId))
/// ```
///
/// 因此 **Latest 不能分页**；要「加载更多」只能加大 `Limit`。
/// 官方文档页提到支持 `StartIndex`，但 OpenAPI 标为数组，两者冲突 ——
/// 【待验证】实测传 `StartIndex=20` 看返回是否变化。
///
/// ## `GroupItems`
///
/// 默认 `true`：同一容器的条目合并成一个（如最新剧集按剧聚合），`ChildCount` 存组内数量。
/// 最新电影：`IncludeItemTypes=Movie&IsPlayed=false`；
/// 最新剧集（按剧聚合）：`IncludeItemTypes=Episode&GroupItems=true` → 返回 Series 列表。
public struct LatestEndpoint: EmbyEndpoint {
    /// 用户 id。
    public let userId: String

    /// 限定某视图 / 文件夹。
    public let parentId: String?

    /// 条数。该端点没有分页，只能靠它控制数量。
    public let limit: Int?

    /// 额外字段。
    public let fields: [ItemField]

    /// 限定类型。
    public let includeItemTypes: [ItemType]

    /// 只看文件夹。
    public let isFolder: Bool?

    /// 只看已看 / 未看。
    public let isPlayed: Bool?

    /// 是否把同一容器的条目聚合。
    public let groupItems: Bool?

    /// 每种图片类型最多返回几个。
    public let imageTypeLimit: Int?

    /// 只返回这些图片类型。
    public let enableImageTypes: [ImageKind]

    /// 是否返回 `UserData`。
    public let enableUserData: Bool?

    /// 以最常用参数创建。
    ///
    /// - Parameters:
    ///   - userId: 用户 id。
    ///   - parentId: 限定视图。
    ///   - limit: 条数。
    ///   - includeItemTypes: 限定类型。
    ///   - groupItems: 是否聚合。
    public init(
        userId: String,
        parentId: String? = nil,
        limit: Int? = 20,
        includeItemTypes: [ItemType] = [],
        groupItems: Bool? = nil
    ) {
        self.userId = userId
        self.parentId = parentId
        self.limit = limit
        self.fields = [.primaryImageAspectRatio, .productionYear, .userData, .runTimeTicks]
        self.includeItemTypes = includeItemTypes
        self.isFolder = nil
        self.isPlayed = nil
        self.groupItems = groupItems
        self.imageTypeLimit = 1
        self.enableImageTypes = [.primary, .backdrop, .thumb]
        self.enableUserData = true
    }

    /// `/Users/{userId}/Items/Latest`。
    public var path: String { "/Users/\(userId)/Items/Latest" }

    /// 查询参数。
    public var query: [String: String] {
        var accumulator = QueryAccumulator()
        accumulator.put("ParentId", parentId)
        accumulator.put("Limit", limit)
        accumulator.putList("Fields", fields)
        accumulator.putList("IncludeItemTypes", includeItemTypes)
        accumulator.put("IsFolder", isFolder)
        accumulator.put("IsPlayed", isPlayed)
        accumulator.put("GroupItems", groupItems)
        accumulator.put("ImageTypeLimit", imageTypeLimit)
        accumulator.putList("EnableImageTypes", enableImageTypes)
        accumulator.put("EnableUserData", enableUserData)
        return accumulator.values
    }
}

// MARK: - 下一集

/// `GET /Shows/NextUp` —— 「接下来看什么」（剧集首页）。
///
/// 官方文档：<https://dev.emby.media/reference/RestAPI/TvShowsService/getShowsNextup.html>
///
/// 语义：用户看过但没看完的剧返回**下一集**；从未看过的剧通常从 S01E01 开始。
/// 返回 ``ItemsQueryResult``（`QueryResult`，**不是数组**）。
public struct NextUpEndpoint: EmbyEndpoint {
    /// 用户 id（必填）。
    public let userId: String

    /// 限定某剧。
    public let seriesId: String?

    /// 限定某视图 / 文件夹。
    public let parentId: String?

    /// 分页起点。
    public let startIndex: Int?

    /// 条数。
    public let limit: Int?

    /// 额外字段。
    public let fields: [ItemField]

    /// 每种图片类型最多返回几个。
    public let imageTypeLimit: Int?

    /// 只返回这些图片类型。
    public let enableImageTypes: [ImageKind]

    /// 是否返回 `UserData`。
    public let enableUserData: Bool?

    /// 以最常用参数创建。
    ///
    /// - Parameters:
    ///   - userId: 用户 id。
    ///   - seriesId: 限定某剧。
    ///   - limit: 条数。
    public init(userId: String, seriesId: String? = nil, limit: Int? = 24) {
        self.userId = userId
        self.seriesId = seriesId
        self.parentId = nil
        self.startIndex = nil
        self.limit = limit
        self.fields = [.overview, .userData, .primaryImageAspectRatio, .runTimeTicks]
        self.imageTypeLimit = 1
        self.enableImageTypes = [.primary, .backdrop, .thumb]
        self.enableUserData = true
    }

    /// `/Shows/NextUp`。
    public var path: String { "/Shows/NextUp" }

    /// 查询参数。
    public var query: [String: String] {
        var accumulator = QueryAccumulator()
        accumulator.put("UserId", userId)
        accumulator.put("SeriesId", seriesId)
        accumulator.put("ParentId", parentId)
        accumulator.put("StartIndex", startIndex)
        accumulator.put("Limit", limit)
        accumulator.putList("Fields", fields)
        accumulator.put("ImageTypeLimit", imageTypeLimit)
        accumulator.putList("EnableImageTypes", enableImageTypes)
        accumulator.put("EnableUserData", enableUserData)
        return accumulator.values
    }
}

// MARK: - 条目详情

/// `GET /Users/{userId}/Items/{itemId}` —— 单条目详情。
///
/// 官方文档：<https://dev.emby.media/reference/RestAPI/UserLibraryService/getUsersByUseridItemsById.html>
///
/// 官方明确：单条查询**返回完整 `BaseItemDto`**，不需要 `Fields`
/// （“When you request a single item using the /Users/{UserId}/Items/{Id} api,
/// you will get back the entire item.”，
/// <https://dev.emby.media/doc/restapi/Browsing-the-Library.html>）。
///
/// 返回 ``PrismCore/MediaItem``；`People` / `MediaSources` 等详情字段可能为 `nil`，
/// 取决于服务器配置。
public struct ItemDetailEndpoint: EmbyEndpoint {
    /// 用户 id。
    public let userId: String

    /// 条目 id。
    public let itemId: String

    /// 以用户 id 与条目 id 创建。
    ///
    /// - Parameters:
    ///   - userId: 用户 id。
    ///   - itemId: 条目 id。
    public init(userId: String, itemId: String) {
        self.userId = userId
        self.itemId = itemId
    }

    /// `/Users/{userId}/Items/{itemId}`。
    public var path: String { "/Users/\(userId)/Items/\(itemId)" }
}

// MARK: - 集列表

/// `GET /Shows/{seriesId}/Episodes` —— 某剧的集列表。
///
/// 官方文档：<https://dev.emby.media/reference/RestAPI/TvShowsService/getShowsByIdEpisodes.html>
///
/// 返回 ``ItemsQueryResult``。`SeasonId`（季 id）与 ``season``（季号）**二选一**。
public struct EpisodesEndpoint: EmbyEndpoint {
    /// 剧集 id。
    public let seriesId: String

    /// 用户 id（带上才有 `UserData`）。
    public let userId: String?

    /// 季 id。
    public let seasonId: String?

    /// 季号（与 ``seasonId`` 二选一）。
    public let season: Int?

    /// 只看缺失集。
    public let isMissing: Bool?

    /// 返回某集的兄弟集（上下集）。
    public let adjacentTo: String?

    /// 从某集开始。
    public let startItemId: String?

    /// 分页起点。
    public let startIndex: Int?

    /// 条数。
    public let limit: Int?

    /// 额外字段。
    public let fields: [ItemField]

    /// 排序字段。
    public let sortBy: [ItemSortBy]

    /// 排序方向（自动补齐到与 `sortBy` 等长）。
    public let sortOrder: [SortOrder]

    /// 每种图片类型最多返回几个。
    public let imageTypeLimit: Int?

    /// 只返回这些图片类型。
    public let enableImageTypes: [ImageKind]

    /// 是否返回 `UserData`。
    public let enableUserData: Bool?

    /// 以剧集 id + 用户 id 创建（按季号 + 集号升序，这是详情页最常用的顺序）。
    ///
    /// - Parameters:
    ///   - seriesId: 剧集 id。
    ///   - userId: 用户 id。
    ///   - seasonId: 季 id；`nil` 表示全部季。
    public init(seriesId: String, userId: String? = nil, seasonId: String? = nil) {
        self.seriesId = seriesId
        self.userId = userId
        self.seasonId = seasonId
        self.season = nil
        self.isMissing = nil
        self.adjacentTo = nil
        self.startItemId = nil
        self.startIndex = nil
        self.limit = nil
        self.fields = [.overview, .userData, .runTimeTicks, .primaryImageAspectRatio, .mediaSources]
        self.sortBy = [ItemSortBy(rawValue: "ParentIndexNumber"), ItemSortBy(rawValue: "IndexNumber")]
        self.sortOrder = [.ascending, .ascending]
        self.imageTypeLimit = 1
        self.enableImageTypes = [.primary, .thumb]
        self.enableUserData = true
    }

    /// `/Shows/{seriesId}/Episodes`。
    public var path: String { "/Shows/\(seriesId)/Episodes" }

    /// 查询参数。
    public var query: [String: String] {
        var accumulator = QueryAccumulator()
        accumulator.put("UserId", userId)
        accumulator.put("SeasonId", seasonId)
        accumulator.put("Season", season)
        accumulator.put("IsMissing", isMissing)
        accumulator.put("AdjacentTo", adjacentTo)
        accumulator.put("StartItemId", startItemId)
        accumulator.put("StartIndex", startIndex)
        accumulator.put("Limit", limit)
        accumulator.putList("Fields", fields)
        accumulator.putList("SortBy", sortBy)
        accumulator.putList("SortOrder", normalizedSortOrder)
        accumulator.put("ImageTypeLimit", imageTypeLimit)
        accumulator.putList("EnableImageTypes", enableImageTypes)
        accumulator.put("EnableUserData", enableUserData)
        return accumulator.values
    }

    /// 补齐 `SortOrder`，保证与 `SortBy` 等长。
    public var normalizedSortOrder: [SortOrder] {
        guard sortOrder.count < sortBy.count else { return sortOrder }
        return sortOrder + Array(repeating: .ascending, count: sortBy.count - sortOrder.count)
    }
}

// MARK: - 季列表

/// `GET /Shows/{seriesId}/Seasons` —— 某剧的季列表。
///
/// 官方文档：<https://dev.emby.media/reference/RestAPI/TvShowsService/getShowsByIdSeasons.html>
///
/// 返回 ``ItemsQueryResult``。
public struct SeasonsEndpoint: EmbyEndpoint {
    /// 剧集 id。
    public let seriesId: String

    /// 用户 id（带上才有 `UserData`）。
    public let userId: String?

    /// 只看 / 排除特别季。
    public let isSpecialSeason: Bool?

    /// 只看缺失集。
    public let isMissing: Bool?

    /// 额外字段。
    public let fields: [ItemField]

    /// 每种图片类型最多返回几个。
    public let imageTypeLimit: Int?

    /// 只返回这些图片类型。
    public let enableImageTypes: [ImageKind]

    /// 是否返回 `UserData`。
    public let enableUserData: Bool?

    /// 以剧集 id + 用户 id 创建。
    ///
    /// - Parameters:
    ///   - seriesId: 剧集 id。
    ///   - userId: 用户 id。
    public init(seriesId: String, userId: String? = nil) {
        self.seriesId = seriesId
        self.userId = userId
        self.isSpecialSeason = nil
        self.isMissing = nil
        self.fields = [.overview, .userData, .primaryImageAspectRatio, .childCount]
        self.imageTypeLimit = 1
        self.enableImageTypes = [.primary, .thumb]
        self.enableUserData = true
    }

    /// `/Shows/{seriesId}/Seasons`。
    public var path: String { "/Shows/\(seriesId)/Seasons" }

    /// 查询参数。
    public var query: [String: String] {
        var accumulator = QueryAccumulator()
        accumulator.put("UserId", userId)
        accumulator.put("IsSpecialSeason", isSpecialSeason)
        accumulator.put("IsMissing", isMissing)
        accumulator.putList("Fields", fields)
        accumulator.put("ImageTypeLimit", imageTypeLimit)
        accumulator.putList("EnableImageTypes", enableImageTypes)
        accumulator.put("EnableUserData", enableUserData)
        return accumulator.values
    }
}

// MARK: - 相似内容

/// `GET /Items/{itemId}/Similar` —— 相似推荐。
///
/// 官方文档：<https://dev.emby.media/reference/RestAPI/LibraryService/getItemsByIdSimilar.html>
///
/// - Important: 返回 **`QueryResult`**（不是数组）：
///   `let page: ItemsQueryResult = try await client.send(...)`。
public struct SimilarEndpoint: EmbyEndpoint {
    /// 条目 id。
    public let itemId: String

    /// 用户 id（带上才有 `UserData`）。
    public let userId: String?

    /// 限定类型（如只要 `Movie`）。
    public let includeItemTypes: [ItemType]

    /// 条数。
    public let limit: Int?

    /// 额外字段。
    public let fields: [ItemField]

    /// 每种图片类型最多返回几个。
    public let imageTypeLimit: Int?

    /// 只返回这些图片类型。
    public let enableImageTypes: [ImageKind]

    /// 是否返回 `UserData`。
    public let enableUserData: Bool?

    /// 以条目 id + 用户 id 创建。
    ///
    /// - Parameters:
    ///   - itemId: 条目 id。
    ///   - userId: 用户 id。
    ///   - limit: 条数。
    public init(itemId: String, userId: String? = nil, limit: Int? = 12) {
        self.itemId = itemId
        self.userId = userId
        self.includeItemTypes = []
        self.limit = limit
        self.fields = [.primaryImageAspectRatio, .productionYear, .userData]
        self.imageTypeLimit = 1
        self.enableImageTypes = [.primary]
        self.enableUserData = true
    }

    /// `/Items/{itemId}/Similar`。
    public var path: String { "/Items/\(itemId)/Similar" }

    /// 查询参数。
    public var query: [String: String] {
        var accumulator = QueryAccumulator()
        accumulator.put("UserId", userId)
        accumulator.putList("IncludeItemTypes", includeItemTypes)
        accumulator.put("Limit", limit)
        accumulator.putList("Fields", fields)
        accumulator.put("ImageTypeLimit", imageTypeLimit)
        accumulator.putList("EnableImageTypes", enableImageTypes)
        accumulator.put("EnableUserData", enableUserData)
        return accumulator.values
    }
}
