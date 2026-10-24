import EmbyAPI
import Foundation
import Observation
import PrismCore

// MARK: - 查询默认值

/// 网格分页请求里固定的字段与图片参数。
///
/// **为什么不直接用 `ItemField.defaultFields`**：默认字段包含 `People` /
/// `MediaSources` / `MediaStreams`，那是详情页才需要的重字段。海报墙一次要 60 条，
/// 带上它们会让响应体大好几倍，而网格一个都用不到（见 `ItemsQuery` 顶部第 1 条坑）。
/// 列表模式需要 `Overview`，因此这里显式保留它。
private enum LibraryQueryDefaults {
    /// 网格 / 列表都用得到的字段。
    static let fields: [ItemField] = [
        .primaryImageAspectRatio,
        .productionYear,
        .runTimeTicks,
        .userData,
        .communityRating,
        .officialRating,
        .genres,
        .overview,
        .childCount,
        .dateCreated,
        .premiereDate
    ]

    /// 每页条数。
    static let pageSize = 60

    /// 距离末尾多少条时预取下一页。
    static let prefetchDistance = 10
}

// MARK: - 视图模型

/// 媒体库网格的视图模型（`docs/ARCHITECTURE.md` §5.3 的冻结契约）。
///
/// 职责：
/// - 维护 ``state``（`LoadState<[MediaItem]>` 四态）与 ``totalCount``；
/// - 分页：每页 60 条，滚动到倒数第 10 条时预取下一页；
/// - 排序 / 筛选变化时**重置到第一页并清空已有数据**；
/// - 接受外部注入的 ``searchTerm``（工具栏搜索框），300ms 防抖后重新查询。
///
/// 不 import SwiftUI，也不知道 `PosterCard` 长什么样——这是 §5.3 的硬规则，
/// 让 VM 可以在没有 UI 的环境里被测试。
///
/// ## 并发与乱序保护
///
/// 每次「重载第一页」都会让内部 ``generation`` 自增；请求返回后如果发现
/// generation 已经变了（用户又换了排序 / 筛选 / 搜索词），结果会被**丢弃**，
/// 避免「旧请求后到、把新结果覆盖掉」这种经典分页竞态。
///
/// ## 用法
///
/// ```swift
/// let viewModel = LibraryViewModel(dataSource: dataSource, libraryId: view.id, kind: .video)
/// await viewModel.loadFirstPage()
/// viewModel.searchTerm = navigation.searchText      // 自动防抖重查
/// await viewModel.apply(sort: .rating)              // 改排序 = 重载第一页
/// ```
@MainActor
@Observable
public final class LibraryViewModel {
    // MARK: 常量

    /// 每页条数。
    public static let pageSize = LibraryQueryDefaults.pageSize

    /// 距末尾多少条时触发预取。
    public static let prefetchDistance = LibraryQueryDefaults.prefetchDistance

    /// 搜索防抖时长（毫秒），与 UX 文档 §S14「输入 300ms 防抖请求」一致。
    public static let searchDebounceMilliseconds = 300

    /// 筛选防抖时长（毫秒）。
    ///
    /// 评分滑块每 0.5 分触发一次变更，拖动一次会产生十几次回调。
    /// 250ms 足够让人「停下来」再发请求，又不会觉得卡。
    public static let filterDebounceMilliseconds = 250

    // MARK: 状态

    /// 当前加载状态。
    public private(set) var state: LoadState<[MediaItem]>

    /// 是否正在加载下一页（防止重复请求）。
    public private(set) var isLoadingMore: Bool

    /// 服务端返回的**过滤后**总数（不是本页条数）。
    public private(set) var totalCount: Int

    /// 非阻塞的内联错误：刷新失败或标记已看 / 收藏失败时写入。
    ///
    /// 与 ``state`` 的 `.failed` 区分：`.failed` 是「整页没有内容」，
    /// 这里用于「已有内容仍然可用，但刚刚那个操作失败了」，
    /// 对应 UX 文档 §S04「部分内容加载失败（不遮挡已有内容）」。
    public private(set) var inlineError: EmbyError?

    /// 排序方式。
    ///
    /// - Important: 直接赋值**不会**重新加载，请用 ``apply(sort:)``。
    ///   这样拆分是因为「选择排序」与「请求排序结果」在 UI 上是两个动作
    ///   （菜单点完立刻回显选中态，数据稍后到达）。
    public var sort: SortOption

    /// 筛选条件。
    ///
    /// - Important: 直接赋值**不会**重新加载，请用 ``apply(filters:)``。
    public var filters: FilterSet

    /// 网格 / 列表布局。纯展示状态，不影响请求。
    public var layout: GridLayout

    /// 搜索词（外部注入，例如工具栏搜索框）。
    ///
    /// 赋值即触发 300ms 防抖重查；置空则回到无关键词浏览。
    public var searchTerm: String {
        get { storedSearchTerm }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != storedSearchTerm else { return }
            storedSearchTerm = trimmed
            scheduleSearchReload()
        }
    }

    // MARK: 身份

    /// 服务端视图 id。
    public let libraryId: String

    /// 库的内容大类。
    public let kind: MediaKind

    /// 实际发给 `IncludeItemTypes` 的条目类型。
    ///
    /// 默认由 ``kind`` 推导（`.video` → 电影 + 剧集），也可以由调用方精确指定
    /// （例如「电影库」只传 `.movie`，避免把剧集混进海报墙）。
    public let includeItemTypes: [ItemType]

    // MARK: 内部

    /// 数据源。
    @ObservationIgnored private let dataSource: LibraryDataSource

    /// 搜索词的实际存储（``searchTerm`` 是带副作用的计算属性）。
    @ObservationIgnored private var storedSearchTerm: String

    /// 重载代次：用于丢弃过期响应。
    @ObservationIgnored private var generation = 0

    /// 服务端已经没有更多数据（即使 `totalCount` 还说有）。
    @ObservationIgnored private var didReachEnd = false

    /// 防抖用的搜索任务。
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    /// 防抖用的筛选任务。
    @ObservationIgnored private var filterTask: Task<Void, Never>?

    // MARK: - 初始化

    /// 创建媒体库视图模型。
    ///
    /// - Parameters:
    ///   - dataSource: 数据源（生产用 ``EmbyLibraryDataSource``，预览用桩）。
    ///   - libraryId: 服务端视图 id（Emby `/Users/{id}/Views` 返回的 `Id`）。
    ///   - kind: 库的内容大类，决定默认的 `IncludeItemTypes`。
    ///   - includeItemTypes: 精确指定条目类型；`nil` 时由 ``kind`` 推导。
    ///   - sort: 初始排序，默认最近添加。
    ///   - filters: 初始筛选，默认无筛选。
    ///   - layout: 初始布局，默认网格。
    ///   - searchTerm: 初始搜索词，默认空。
    public init(
        dataSource: LibraryDataSource,
        libraryId: String,
        kind: MediaKind,
        includeItemTypes: [ItemType]? = nil,
        sort: SortOption = .recentlyAdded,
        filters: FilterSet = .none,
        layout: GridLayout = .poster,
        searchTerm: String = ""
    ) {
        self.dataSource = dataSource
        self.libraryId = libraryId
        self.kind = kind
        self.includeItemTypes = includeItemTypes ?? Self.defaultItemTypes(for: kind)
        self.state = .idle
        self.isLoadingMore = false
        self.totalCount = 0
        self.inlineError = nil
        self.sort = sort
        self.filters = filters
        self.layout = layout
        self.storedSearchTerm = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 派生状态

    /// 已加载的条目（非 `.loaded` 状态为空数组）。
    public var items: [MediaItem] {
        state.value ?? []
    }

    /// 是否还有下一页。
    public var hasMoreItems: Bool {
        !didReachEnd && items.count < totalCount
    }

    /// 当前筛选 / 搜索是否会让结果为空（决定空态文案用哪一套）。
    public var isFilteredOrSearching: Bool {
        filters.isFiltered || !storedSearchTerm.isEmpty
    }

    /// 可选的类型列表。
    ///
    /// 来源是「已加载条目的 `genres` 并集」：v1.0 不额外请求 `/Genres` 端点
    /// （我们的端点集里没有它），因此这是一个**增量**列表——滚得越多越全。
    /// 已选中的类型始终包含在内，避免翻页后 chip 突然消失。
    public var availableGenres: [String] {
        var names = Set(items.flatMap(\.genres))
        names.formUnion(filters.genres)
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// 条目总数的展示文案（`共 128 部`）。
    ///
    /// - Parameter unit: 量词，默认「部」。
    /// - Returns: 已格式化好的字符串。
    public func totalCountText(unit: String = "部") -> String {
        "共 \(totalCount) \(unit)"
    }

    // MARK: - 加载

    /// 加载第一页（首次进入库时调用）。
    ///
    /// 会把状态切到 `.loading` 并清空已有数据，因此视图会显示骨架屏。
    public func loadFirstPage() async {
        guard !state.isLoading else { return }
        await reloadFirstPage(clearing: true)
    }

    /// 刷新：重新拉第一页，但**保留当前内容**直到新结果到达（⌘R）。
    ///
    /// 失败时不清空列表，只写 ``inlineError``，符合 UX 文档
    /// 「部分内容加载失败：不遮挡已有内容」的要求。
    public func refresh() async {
        guard !state.isLoading else { return }
        await reloadFirstPage(clearing: false)
    }

    /// 滚动到接近末尾时按需加载下一页。
    ///
    /// 触发条件（三者同时满足）：
    /// 1. `currentItem` 位于「倒数第 10 条」及之后；
    /// 2. 还有下一页（``hasMoreItems``）；
    /// 3. 没有正在进行的翻页请求（``isLoadingMore`` 守卫，防重入）。
    ///
    /// - Parameter currentItem: 刚刚出现在屏幕上的条目。
    public func loadMoreIfNeeded(currentItem: MediaItem) async {
        guard case let .loaded(items) = state,
              let index = items.firstIndex(where: { $0.id == currentItem.id })
        else { return }

        guard index >= items.count - Self.prefetchDistance else { return }
        await loadNextPage()
    }

    /// 直接加载下一页（底部「正在加载更多」占位出现时兜底调用）。
    public func loadNextPage() async {
        guard !isLoadingMore, hasMoreItems else { return }
        guard let current = state.value, !current.isEmpty else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }

        let token = generation
        let startIndex = current.count
        do {
            let page = try await dataSource.items(query: makeQuery(startIndex: startIndex))
            guard token == generation else { return }

            totalCount = page.totalRecordCount
            if page.items.isEmpty {
                // 服务端说还有、实际给空了：停止继续请求，避免无限翻页。
                didReachEnd = true
                return
            }

            // 按 id 去重：服务端在并发写入时可能返回重叠页，
            // 直接 append 会让 `ForEach` 出现重复 id（SwiftUI 会警告并渲染错乱）。
            var merged = current
            let existing = Set(merged.map(\.id))
            merged.append(contentsOf: page.items.filter { !existing.contains($0.id) })
            state = .loaded(merged)
        } catch is CancellationError {
            return
        } catch {
            guard token == generation else { return }
            inlineError = Self.normalized(error)
        }
    }

    // MARK: - 排序与筛选

    /// 应用新的排序方式：重置到第一页并清空已有数据。
    ///
    /// 排序是**一次点击**、语义上整页重排，清屏是对的（骨架屏能说明「在重排」）。
    /// 筛选不同，它来自连续拖动的滑块，所以那条路径保留画面（见 ``apply(filters:)``）。
    ///
    /// - Parameter newSort: 新的排序方式。
    public func apply(sort newSort: SortOption) async {
        guard newSort != sort else { return }
        sort = newSort
        await reloadFirstPage(clearing: true)
    }

    /// 应用新的筛选条件：重置到第一页，但**保留当前画面**直到新结果到达。
    ///
    /// 为什么不清屏：筛选条上的评分滑块每 0.5 分就是一次变更，清屏会让整墙海报
    /// 反复打回骨架屏（拖动一次闪十几下）。保留旧内容、只转小菊花，
    /// 与 ⌘R 刷新同一套语义。
    ///
    /// - Parameter newFilters: 新的筛选条件。
    public func apply(filters newFilters: FilterSet) async {
        guard newFilters != filters else { return }
        filters = newFilters
        await reloadFirstPage(clearing: false)
    }

    /// 更新筛选条件（带防抖），供筛选条上的连续控件使用。
    ///
    /// 与 ``apply(filters:)`` 的分工：那个是「立即生效」，测试与一次性动作（清除筛选）
    /// 用它；滑块 / 多选这类高频输入走这里，避免一次拖动连发十几个请求。
    ///
    /// - Parameter newFilters: 新的筛选条件。
    public func scheduleFilters(_ newFilters: FilterSet) {
        guard newFilters != filters else { return }
        filters = newFilters

        filterTask?.cancel()
        filterTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.filterDebounceMilliseconds))
            guard !Task.isCancelled, let self else { return }
            await self.reloadFirstPage(clearing: false)
        }
    }

    /// 清空全部筛选并重新加载。
    public func clearFilters() async {
        filterTask?.cancel()
        filterTask = nil
        await apply(filters: .none)
    }

    // MARK: - 用户数据

    /// 标记已看 / 未看，并就地更新列表里的这一条。
    ///
    /// 不做乐观更新：Emby 会返回权威的 `UserItemData`（可能带级联效果，
    /// 例如对剧集标记已看会连带所有集），以服务端返回值为准更安全。
    ///
    /// - Parameters:
    ///   - played: `true` 标记已看，`false` 标记未看。
    ///   - item: 目标条目。
    public func setPlayed(_ played: Bool, for item: MediaItem) async {
        do {
            let updated = try await dataSource.markPlayed(itemId: item.id, played: played)
            apply(userData: updated, toItemID: item.id)
        } catch is CancellationError {
            return
        } catch {
            inlineError = Self.normalized(error)
        }
    }

    /// 收藏 / 取消收藏，并就地更新列表里的这一条。
    ///
    /// - Parameters:
    ///   - favorite: `true` 收藏，`false` 取消收藏。
    ///   - item: 目标条目。
    public func setFavorite(_ favorite: Bool, for item: MediaItem) async {
        do {
            let updated = try await dataSource.markFavorite(itemId: item.id, favorite: favorite)
            apply(userData: updated, toItemID: item.id)
        } catch is CancellationError {
            return
        } catch {
            inlineError = Self.normalized(error)
        }
    }

    /// 清掉内联错误（用户点「关闭」时调用）。
    public func dismissInlineError() {
        inlineError = nil
    }

    /// 拼海报地址（视图层不该知道 Emby 的图片路径规则）。
    ///
    /// - Parameter item: 条目。
    /// - Returns: 海报地址；没有海报时为 `nil`（``PrismUI/PosterCard`` 会显示占位图）。
    public func posterURL(for item: MediaItem) -> URL? {
        dataSource.imageURL(for: item, kind: .primary, maxWidth: 360)
    }

    /// 拼缩略图地址（列表模式用，比海报小一档）。
    ///
    /// - Parameter item: 条目。
    /// - Returns: 缩略图地址；没有 `Thumb` 时回落到海报。
    public func thumbnailURL(for item: MediaItem) -> URL? {
        if let thumb = dataSource.imageURL(for: item, kind: .thumb, maxWidth: 160) {
            return thumb
        }
        return posterURL(for: item)
    }

    // MARK: - 内部实现

    /// 重载第一页。
    ///
    /// - Parameter clearing: `true` 时先切 `.loading` 并清空计数（首屏 / 换排序 / 换筛选）；
    ///   `false` 时保留当前画面（⌘R 刷新）。
    private func reloadFirstPage(clearing: Bool) async {
        generation &+= 1
        let token = generation

        if clearing {
            state = .loading
            totalCount = 0
            didReachEnd = false
            inlineError = nil
        }

        do {
            let page = try await dataSource.items(query: makeQuery(startIndex: 0))
            guard token == generation else { return }

            totalCount = page.totalRecordCount
            didReachEnd = page.items.isEmpty
            state = page.items.isEmpty ? .empty : .loaded(page.items)
            inlineError = nil
        } catch is CancellationError {
            guard token == generation else { return }
            // 没有更新的请求接手（例如视图消失导致任务取消）：退回 idle，
            // 让下一次进入库时能重新加载，而不是永远卡在骨架屏。
            if clearing, case .loading = state {
                state = .idle
            }
        } catch {
            guard token == generation else { return }
            let normalized = Self.normalized(error)
            if !clearing, case .loaded = state {
                inlineError = normalized
            } else {
                state = .failed(normalized)
            }
        }
    }

    /// 搜索词变化后的防抖重载。
    private func scheduleSearchReload() {
        searchTask?.cancel()
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.searchDebounceMilliseconds))
            guard !Task.isCancelled, let self else { return }
            await self.reloadFirstPage(clearing: true)
        }
    }

    /// 构造发给 `/Users/{id}/Items` 的查询。
    ///
    /// - Parameter startIndex: 分页起点（0 基）。
    /// - Returns: 查询参数。
    private func makeQuery(startIndex: Int) -> ItemsQuery {
        var query = ItemsQuery()
        query.parentId = libraryId
        query.recursive = true
        query.includeItemTypes = includeItemTypes
        query.fields = LibraryQueryDefaults.fields
        query.sortBy = sort.sortBy
        query.sortOrder = sort.sortOrders
        query.startIndex = max(startIndex, 0)
        query.limit = Self.pageSize
        query.enableImages = true
        query.enableUserData = true
        query.imageTypeLimit = 1
        query.enableImageTypes = [.primary, .thumb]

        // 筛选：分隔符由 ItemsQuery 负责（Genres 用 `|`，Years 用 `,`）。
        query.isPlayed = filters.isPlayed
        query.genres = filters.genreList
        query.years = filters.years
        query.minCommunityRating = filters.minCommunityRating

        let keyword = storedSearchTerm
        if !keyword.isEmpty {
            query.searchTerm = keyword
        }
        return query
    }

    /// 把服务端返回的用户数据写回列表。
    ///
    /// - Parameters:
    ///   - userData: 新的用户数据。
    ///   - id: 条目 id。
    private func apply(userData: UserItemData, toItemID id: String) {
        guard case let .loaded(items) = state,
              let index = items.firstIndex(where: { $0.id == id })
        else { return }
        var updated = items
        updated[index] = updated[index].replacing(userData: userData)
        state = .loaded(updated)
    }

    /// 把任意错误归一化成 ``PrismCore/EmbyError``。
    ///
    /// - Parameter error: 原始错误。
    /// - Returns: 统一的 Emby 错误。
    private static func normalized(_ error: any Error) -> EmbyError {
        if let emby = error as? EmbyError { return emby }
        return .unknown(String(describing: error))
    }

    /// 按内容大类推导 `IncludeItemTypes`。
    ///
    /// - Parameter kind: 媒体大类。
    /// - Returns: 条目类型列表；未知大类返回空数组（= 服务端不限制类型）。
    private static func defaultItemTypes(for kind: MediaKind) -> [ItemType] {
        switch kind {
        case .video:
            [.movie, .series]
        case .audio:
            [.audio, .musicAlbum]
        case .photo:
            [.photo]
        case .book:
            [.book]
        default:
            []
        }
    }
}

// MARK: - 条目用户数据替换

private extension MediaItem {
    /// 返回只替换了 `userData` 的副本。
    ///
    /// `MediaItem` 的字段全是 `let`，标记已看 / 收藏后就地更新只能重建。
    /// 这里集中一处，避免每个调用点抄 24 个参数。
    ///
    /// - Parameter userData: 新的用户数据。
    /// - Returns: 新条目。
    func replacing(userData: UserItemData) -> MediaItem {
        MediaItem(
            id: id,
            name: name,
            type: type,
            serverId: serverId,
            productionYear: productionYear,
            runTime: runTime,
            overview: overview,
            officialRating: officialRating,
            communityRating: communityRating,
            genres: genres,
            imageTags: imageTags,
            backdropTags: backdropTags,
            seriesPrimaryImageTag: seriesPrimaryImageTag,
            primaryImageItemId: primaryImageItemId,
            parentBackdropItemId: parentBackdropItemId,
            parentBackdropTags: parentBackdropTags,
            parentThumbItemId: parentThumbItemId,
            parentThumbImageTag: parentThumbImageTag,
            parentLogoItemId: parentLogoItemId,
            parentLogoImageTag: parentLogoImageTag,
            userData: userData,
            seriesId: seriesId,
            seasonId: seasonId,
            indexNumber: indexNumber,
            parentIndexNumber: parentIndexNumber,
            seriesName: seriesName,
            mediaSources: mediaSources,
            people: people,
            childCount: childCount,
            originalTitle: originalTitle,
            dateCreated: dateCreated,
            premiereDate: premiereDate,
            isFolder: isFolder
        )
    }
}
