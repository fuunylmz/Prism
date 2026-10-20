import AppKit
import Foundation
import PrismCore

/// 演示模式可以模拟的故障类型，用于验证 UI 的「错误态 / 空态」。
///
/// 三态是 UI 的硬性要求（见 `docs/ARCHITECTURE.md` §7「UI 用 `#Preview` 覆盖三态」）：
/// 有数据 / 空 / 错误。``emptyLibrary`` 不是错误，它是「空态」——
/// 服务端正常响应，只是没有内容，因此**返回空数组而不是抛错**。
public enum DemoFailure: String, Sendable, Hashable, CaseIterable {
    /// 请求超时（对应 ``PrismCore/EmbyError/timeout``）。
    case timeout
    /// 令牌失效（对应 ``PrismCore/EmbyError/unauthorized``，UI 应跳回登录页）。
    case unauthorized
    /// 空库：所有列表返回空数组，**不抛错**。
    case emptyLibrary
    /// 服务器内部错误（对应 ``PrismCore/EmbyError/server(status:message:)``，500）。
    case serverError

    /// 该故障对应的错误；``emptyLibrary`` 没有错误（它是空态而不是错误态）。
    public var error: EmbyError? {
        switch self {
        case .timeout: .timeout
        case .unauthorized: .unauthorized
        case .serverError: .server(status: 500, message: "演示模式：模拟服务器内部错误")
        case .emptyLibrary: nil
        }
    }

    /// 是否属于「应该展示错误界面」的故障。
    public var isError: Bool {
        self != .emptyLibrary
    }
}

/// 与 ``EmbyClient`` 同构的演示客户端：不联网，所有数据来自 ``DemoLibrary``。
///
/// ## 为什么要「同构」而不是随便造一个 mock
///
/// UI 层只依赖这一组方法签名。只要演示实现与真实实现在**行为语义**上一致
/// （分页、搜索、排序、筛选、字段形态），把 `DemoEmbyClient` 换成 `EmbyClient`
/// 就不需要改任何 UI 代码。因此这里刻意复刻了真实端点的几个易错点：
///
/// | 语义 | 真实端点的行为 | 本实现 |
/// |---|---|---|
/// | 分页 | `StartIndex` + `Limit`，`TotalRecordCount` 是**过滤后**总数 | 同左 |
/// | 搜索 | `SearchTerm` 模糊匹配标题 / 原名 / 演员 | 同左（大小写不敏感、子串匹配） |
/// | 排序 | `SortBy` 与 `SortOrder` 按位置一一对应 | 同左，缺项补 `Ascending` |
/// | 筛选 | `IsPlayed` / `Genres` / `Years` / `Filters` | 同左 |
/// | 列表不带 `People` / `MediaSources` | 只有详情接口返回 | 同左（``DemoLibrary/detailCopy(of:)`` 才补） |
///
/// ## 延迟与故障注入
///
/// ```swift
/// let slow = DemoEmbyClient(delay: .milliseconds(800))          // 看骨架屏
/// let broken = DemoEmbyClient(failure: .timeout)                // 看错误态
/// let empty = DemoEmbyClient(failure: .emptyLibrary)            // 看空态
/// ```
///
/// ## 并发
///
/// 本类型是 `actor`，与 ``EmbyClient`` 一样天然串行化状态访问；数据本身是只读的
/// 静态目录，因此即使并发调用也不会出现数据竞争。
public actor DemoEmbyClient {

    /// 默认实例：无延迟、无故障，供 App 在演示模式下直接使用。
    public static let shared = DemoEmbyClient()

    /// 每个请求的人为延迟；`nil` 表示立即返回。
    private let delay: Duration?

    /// 注入的故障；`nil` 表示一切正常。
    private let failure: DemoFailure?

    /// 日志出口。
    private let logger: any Logging

    /// 创建一个演示客户端。
    ///
    /// - Parameters:
    ///   - delay: 每个请求的人为延迟（用于观察加载态），`nil` 表示不加延迟。
    ///   - failure: 注入的故障（用于观察错误态 / 空态），`nil` 表示正常。
    ///   - logger: 日志出口；`nil` 时使用 `demo` 分类的 ``PrismCore/OSLogger``。
    public init(
        delay: Duration? = nil,
        failure: DemoFailure? = nil,
        logger: (any Logging)? = nil
    ) {
        self.delay = delay
        self.failure = failure
        self.logger = logger ?? OSLogger(category: "demo")
    }

    // MARK: - 认证

    /// 演示登录：任意用户名 + 密码都能成功，**空用户名**返回
    /// ``PrismCore/EmbyError/unauthorized``。
    ///
    /// 之所以允许任意密码：演示模式的目的就是让人「点一下就能进去」，
    /// 不该强迫用户记住一个假密码。空用户名则必须失败——登录页的
    /// 「用户名为空」校验需要有真实的错误路径可以验证。
    ///
    /// - Parameters:
    ///   - username: 用户名（去掉首尾空白后不能为空）。
    ///   - password: 密码（演示模式不校验）。
    /// - Returns: 有效会话。
    /// - Throws: ``PrismCore/EmbyError/unauthorized`` 当用户名为空；
    ///   或注入的 ``DemoFailure`` 对应的错误。
    public func authenticate(username: String, password: String) async throws -> AuthSession {
        try await prepare()

        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            logger.warning("演示模式登录被拒绝：用户名为空")
            throw EmbyError.unauthorized
        }
        _ = password

        let user = EmbyUser(
            id: DemoLibrary.userId,
            name: trimmed,
            serverId: DemoLibrary.serverId,
            isAdministrator: true,
            serverName: DemoLibrary.serverName,
            hasPassword: true,
            lastLoginDate: DemoLibrary.referenceDate
        )
        let session = AuthSession(
            serverId: DemoLibrary.serverId,
            userId: DemoLibrary.userId,
            accessToken: "demo-token-\(DemoLibrary.stableID("token:" + trimmed).prefix(16))",
            user: user,
            createdAt: DemoLibrary.referenceDate
        )
        logger.info("演示模式登录成功", metadata: ["user": session.user.name])
        return session
    }

    // MARK: - 媒体库

    /// 顶层媒体库视图（电影 / 剧集 / 合集）。
    ///
    /// - Parameter userId: 用户 id（演示模式不校验）。
    /// - Returns: 视图数组，带 `CollectionType`。
    /// - Throws: 注入的 ``DemoFailure`` 对应的错误。
    public func views(userId: String) async throws -> [MediaView] {
        try await prepare()
        guard !isLibraryEmpty else { return [] }
        return DemoLibrary.views
    }

    /// 顶层媒体库视图的**扁平版**（只保留通用条目字段）。
    ///
    /// 用于不关心 `CollectionType` 的调用点；语义与 ``views(userId:)`` 完全一致。
    ///
    /// - Parameter userId: 用户 id。
    /// - Returns: 条目数组。
    /// - Throws: 注入的 ``DemoFailure`` 对应的错误。
    public func viewItems(userId: String) async throws -> [MediaItem] {
        let list = try await views(userId: userId)
        return list.map(\.item)
    }

    /// 列表查询（浏览 / 搜索 / 筛选 / 分页）。
    ///
    /// 语义与 `/Users/{userId}/Items` 对齐：`totalRecordCount` 是**过滤后**的总数，
    /// 分页只影响 `items`。`StartIndex` 超出总数时返回空页而不是报错。
    ///
    /// - Parameters:
    ///   - userId: 用户 id。
    ///   - query: 查询参数。
    /// - Returns: 分页结果。
    /// - Throws: 注入的 ``DemoFailure`` 对应的错误。
    public func items(userId: String, query: ItemsQuery = ItemsQuery()) async throws -> ItemsQueryResult {
        try await prepare()
        let startIndex = max(query.startIndex ?? 0, 0)
        guard !isLibraryEmpty else {
            return ItemsQueryResult(items: [], totalRecordCount: 0, startIndex: startIndex)
        }

        let candidates = candidateItems(for: query)
        let filtered = filter(candidates, by: query)
        let sorted = sort(filtered, by: query)
        let page = paginate(sorted, startIndex: startIndex, limit: query.limit)
        return ItemsQueryResult(items: page, totalRecordCount: sorted.count, startIndex: startIndex)
    }

    /// 「继续观看」：有播放进度且未看完的条目，按上次播放时间倒序。
    ///
    /// - Parameters:
    ///   - userId: 用户 id。
    ///   - limit: 最多返回条数。
    /// - Returns: 条目数组。
    /// - Throws: 注入的 ``DemoFailure`` 对应的错误。
    public func resume(userId: String, limit: Int = 20) async throws -> [MediaItem] {
        try await prepare()
        guard !isLibraryEmpty else { return [] }
        let inProgress = DemoLibrary.allItems.filter(\.isResumable)
        let sorted = inProgress.sorted { lhs, rhs in
            let left = lhs.userData.lastPlayedDate ?? .distantPast
            let right = rhs.userData.lastPlayedDate ?? .distantPast
            if left != right { return left > right }
            return lhs.id < rhs.id
        }
        return Array(sorted.prefix(max(limit, 0)))
    }

    /// 「最新添加」：按入库时间倒序。
    ///
    /// - Parameters:
    ///   - userId: 用户 id。
    ///   - parentId: 限定媒体库；`nil` 表示全库。
    ///   - limit: 最多返回条数。
    /// - Returns: 条目数组。
    /// - Throws: 注入的 ``DemoFailure`` 对应的错误。
    public func latest(userId: String, parentId: String? = nil, limit: Int = 20) async throws -> [MediaItem] {
        try await prepare()
        guard !isLibraryEmpty else { return [] }
        var candidates = DemoLibrary.allItems
        if let parentId {
            candidates = candidates.filter { item in
                switch parentId {
                case DemoLibrary.moviesLibraryId: item.type == .movie
                case DemoLibrary.tvShowsLibraryId: item.type == .series
                case DemoLibrary.collectionsLibraryId: item.type == .boxSet
                default: item.seriesId == parentId
                }
            }
        }
        let sorted = candidates.sorted { lhs, rhs in
            let left = lhs.dateCreated ?? .distantPast
            let right = rhs.dateCreated ?? .distantPast
            if left != right { return left > right }
            return lhs.id < rhs.id
        }
        return Array(sorted.prefix(max(limit, 0)))
    }

    /// 「接下来看什么」：每部有观看记录的剧，返回下一集。
    ///
    /// 与 `/Shows/NextUp` 一致：**只返回已经开始看的剧**，没看过的剧不出现在这里。
    ///
    /// - Parameters:
    ///   - userId: 用户 id。
    ///   - seriesId: 限定某部剧；`nil` 表示全部。
    ///   - limit: 最多返回条数。
    /// - Returns: 单集数组。
    /// - Throws: 注入的 ``DemoFailure`` 对应的错误。
    public func nextUp(userId: String, seriesId: String? = nil, limit: Int = 24) async throws -> [MediaItem] {
        try await prepare()
        guard !isLibraryEmpty else { return [] }

        let series = DemoLibrary.series.filter { seriesId == nil || $0.id == seriesId }
        var result: [MediaItem] = []
        for show in series {
            let episodes = DemoLibrary.episodes(ofSeries: show.id)
            guard !episodes.isEmpty else { continue }
            let lastWatched = episodes.lastIndex { $0.userData.played }
            guard let lastWatched else { continue }
            let nextIndex = episodes.index(after: lastWatched)
            guard nextIndex < episodes.endIndex else { continue }
            let next = episodes[nextIndex]
            guard !next.userData.played else { continue }
            result.append(next)
        }
        return Array(result.prefix(max(limit, 0)))
    }

    /// 单条目详情：返回全量字段（含 `Overview` / `Genres` / `People` / `MediaSources`）。
    ///
    /// - Parameters:
    ///   - userId: 用户 id。
    ///   - itemId: 条目 id。
    /// - Returns: 详情形态的条目。
    /// - Throws: ``PrismCore/EmbyError/notFound`` 当 id 不存在；或注入的故障。
    public func itemDetail(userId: String, itemId: String) async throws -> MediaItem {
        try await prepare()
        guard let item = DemoLibrary.item(id: itemId) else {
            logger.warning("演示模式详情请求命中未知 id", metadata: ["itemId": itemId])
            throw EmbyError.notFound
        }
        return DemoLibrary.detailCopy(of: item)
    }

    /// 某剧的集列表，按「季号 → 集号」升序。
    ///
    /// - Parameters:
    ///   - seriesId: 剧 id。
    ///   - userId: 用户 id（演示模式不校验，保留参数是为了与真实端点同构）。
    ///   - seasonId: 限定某一季；`nil` 表示全部季。
    /// - Returns: 单集数组。
    /// - Throws: 注入的 ``DemoFailure`` 对应的错误。
    public func episodes(seriesId: String, userId: String? = nil, seasonId: String? = nil) async throws -> [MediaItem] {
        try await prepare()
        guard !isLibraryEmpty else { return [] }
        let all = DemoLibrary.episodes(ofSeries: seriesId)
        guard let seasonId else { return all }
        return all.filter { $0.seasonId == seasonId }
    }

    /// 某剧的季列表，按季号升序。
    ///
    /// - Parameters:
    ///   - seriesId: 剧 id。
    ///   - userId: 用户 id。
    /// - Returns: 季数组。
    /// - Throws: 注入的 ``DemoFailure`` 对应的错误。
    public func seasons(seriesId: String, userId: String? = nil) async throws -> [MediaItem] {
        try await prepare()
        guard !isLibraryEmpty else { return [] }
        return DemoLibrary.seasons(ofSeries: seriesId)
    }

    /// 相似内容：按类型标签重合度打分。
    ///
    /// 打分规则与「看起来合理」对齐，不追求与 Emby 的推荐算法一致：
    /// 重合的 `Genres` 越多分越高，同分时评分高者优先。
    ///
    /// - Parameters:
    ///   - userId: 用户 id。
    ///   - itemId: 条目 id。
    ///   - limit: 最多返回条数。
    /// - Returns: 相似条目数组。
    /// - Throws: ``PrismCore/EmbyError/notFound`` 当 id 不存在；或注入的故障。
    public func similar(userId: String, itemId: String, limit: Int = 12) async throws -> [MediaItem] {
        try await prepare()
        guard !isLibraryEmpty else { return [] }
        guard let anchor = DemoLibrary.item(id: itemId) else { throw EmbyError.notFound }
        let anchorGenres = Set(anchor.genres)

        let scored: [(item: MediaItem, score: Int)] = DemoLibrary.allItems
            .filter { $0.id != anchor.id && $0.type != .season }
            .compactMap { item in
                let overlap = anchorGenres.intersection(Set(item.genres)).count
                guard overlap > 0 else { return nil }
                return (item, overlap)
            }
        let sorted = scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let left = lhs.item.communityRating ?? 0
            let right = rhs.item.communityRating ?? 0
            if left != right { return left > right }
            return lhs.item.id < rhs.item.id
        }
        return sorted.prefix(max(limit, 0)).map { $0.item }
    }

    // MARK: - 图片

    /// 取条目图片（**代码生成的渐变占位图**，不联网、不读磁盘）。
    ///
    /// 同一 `itemId` + `kind` + `size` 永远得到同一张图，因此可以安全地被
    /// 图片缓存层重复请求。
    ///
    /// 种子**只用 `itemId`**（不掺入 `kind`），这样同一部作品的海报与背景图共享同一套
    /// 色相身份，只是构图不同 —— 与 `PrismUI` 里按 URL 生成的路径保持一致，
    /// 两条取图路径不会出现同一部电影两种颜色。
    ///
    /// - Parameters:
    ///   - itemId: 条目 id（未知 id 也会生成一张图，不会抛错）。
    ///   - kind: 图片类型。
    ///   - size: 目标尺寸（点）。
    /// - Returns: 生成的图片。
    /// - Throws: 注入的 ``DemoFailure`` 对应的错误。
    public func image(itemId: String, kind: ImageKind, size: CGSize) async throws -> NSImage {
        try await prepare()
        let title = DemoLibrary.item(id: itemId)?.name
        return DemoArtwork.image(
            seed: itemId,
            kind: kind,
            size: size,
            title: title
        )
    }

    // MARK: - 内部：故障与延迟

    /// 空库模式是否生效。
    private var isLibraryEmpty: Bool {
        failure == .emptyLibrary
    }

    /// 统一的延迟 + 故障注入。
    ///
    /// ``DemoFailure/emptyLibrary`` 不会在这里抛错：它是「空态」而不是「错误态」，
    /// 由各方法自己返回空结果，登录也因此可以照常成功（否则根本进不去空库）。
    ///
    /// - Throws: 注入的故障对应的错误。
    private func prepare() async throws {
        if let delay {
            try await Task.sleep(for: delay)
        }
        guard let failure, let error = failure.error else { return }
        logger.debug("演示模式注入故障", metadata: ["failure": failure.rawValue])
        throw error
    }

    // MARK: - 内部：查询

    /// 按 `parentId` 决定候选集合。
    ///
    /// - Parameter query: 查询参数。
    /// - Returns: 候选条目。
    private func candidateItems(for query: ItemsQuery) -> [MediaItem] {
        guard let parentId = query.parentId else { return DemoLibrary.allItems }

        switch parentId {
        case DemoLibrary.moviesLibraryId:
            return DemoLibrary.movies
        case DemoLibrary.tvShowsLibraryId:
            return query.recursive == true
                ? DemoLibrary.series + DemoLibrary.episodes
                : DemoLibrary.series
        case DemoLibrary.collectionsLibraryId:
            return DemoLibrary.collections
        default:
            break
        }

        // 合集内部：返回成员电影。
        let members = DemoLibrary.members(ofCollection: parentId)
        if !members.isEmpty { return members }

        // 剧内部：季（非递归）或全部单集（递归）。
        let seriesEpisodes = DemoLibrary.episodes(ofSeries: parentId)
        if !seriesEpisodes.isEmpty {
            return query.recursive == true ? seriesEpisodes : DemoLibrary.seasons(ofSeries: parentId)
        }

        // 季内部：该季的单集。
        let seasonEpisodes = DemoLibrary.episodes.filter { $0.seasonId == parentId }
        if !seasonEpisodes.isEmpty {
            return seasonEpisodes
        }

        return DemoLibrary.allItems
    }

    /// 应用筛选条件。
    ///
    /// - Parameters:
    ///   - items: 候选条目。
    ///   - query: 查询参数。
    /// - Returns: 过滤后的条目。
    private func filter(_ items: [MediaItem], by query: ItemsQuery) -> [MediaItem] {
        var result = items

        if !query.includeItemTypes.isEmpty {
            let types = Set(query.includeItemTypes)
            result = result.filter { types.contains($0.type) }
        }
        if !query.excludeItemTypes.isEmpty {
            let types = Set(query.excludeItemTypes)
            result = result.filter { !types.contains($0.type) }
        }
        if !query.ids.isEmpty {
            let ids = Set(query.ids)
            result = result.filter { ids.contains($0.id) }
        }
        if let searchTerm = query.searchTerm?.trimmingCharacters(in: .whitespacesAndNewlines),
           !searchTerm.isEmpty {
            let needle = searchTerm.lowercased()
            result = result.filter { matchesSearch($0, needle: needle) }
        }
        if let isPlayed = query.isPlayed {
            result = result.filter { $0.userData.played == isPlayed }
        }
        if let isFavorite = query.isFavorite {
            result = result.filter { $0.userData.isFavorite == isFavorite }
        }
        if !query.genres.isEmpty {
            let genres = Set(query.genres)
            result = result.filter { !genres.isDisjoint(with: Set($0.genres)) }
        }
        if !query.years.isEmpty {
            let years = Set(query.years)
            result = result.filter { item in
                guard let year = item.productionYear else { return false }
                return years.contains(year)
            }
        }
        if let minRating = query.minCommunityRating {
            result = result.filter { ($0.communityRating ?? 0) >= minRating }
        }
        if let prefix = query.nameStartsWith?.lowercased(), !prefix.isEmpty {
            result = result.filter { $0.name.lowercased().hasPrefix(prefix) }
        }
        for itemFilter in query.filters {
            switch itemFilter {
            case .isPlayed:
                result = result.filter(\.userData.played)
            case .isUnplayed:
                result = result.filter { !$0.userData.played }
            case .isResumable:
                result = result.filter(\.isResumable)
            case .isFavorite:
                result = result.filter(\.userData.isFavorite)
            case .isFolder:
                result = result.filter(\.isFolder)
            case .isNotFolder:
                result = result.filter { !$0.isFolder }
            default:
                break
            }
        }
        return result
    }

    /// 判断条目是否命中搜索词。
    ///
    /// Emby 的 `SearchTerm` 覆盖标题、原始标题与人物名（官方文档只写了
    /// 「Enter a search term to perform a search request」，具体字段见
    /// <https://dev.emby.media/reference/RestAPI/ItemsService/getUsersByUseridItems.html>）。
    /// ◐ 精确覆盖哪些字段未在官方文档写明；这里取最常用的三项，
    /// 验证方法：对真实服务器分别用演员名与标题片段请求，比对返回。
    ///
    /// - Parameters:
    ///   - item: 条目。
    ///   - needle: 已转小写的搜索词。
    /// - Returns: 是否命中。
    private func matchesSearch(_ item: MediaItem, needle: String) -> Bool {
        if item.name.lowercased().contains(needle) { return true }
        if let original = item.originalTitle?.lowercased(), original.contains(needle) { return true }
        if let seriesName = item.seriesName?.lowercased(), seriesName.contains(needle) { return true }
        if let people = DemoLibrary.people(forItemId: item.id) {
            return people.contains { $0.name.lowercased().contains(needle) }
        }
        return false
    }

    /// 按 `SortBy` / `SortOrder` 排序。
    ///
    /// - Parameters:
    ///   - items: 待排序条目。
    ///   - query: 查询参数。
    /// - Returns: 排序后的条目。
    private func sort(_ items: [MediaItem], by query: ItemsQuery) -> [MediaItem] {
        guard !query.sortBy.isEmpty else {
            return items.sorted { Self.compare($0, $1, by: .sortName) == .orderedAscending }
        }
        let keys = query.sortBy
        let orders = query.normalizedSortOrder
        return items.sorted { lhs, rhs in
            for (index, key) in keys.enumerated() {
                let order = index < orders.count ? orders[index] : .ascending
                let result = Self.compare(lhs, rhs, by: key)
                if result != .orderedSame {
                    return order == .descending
                        ? result == .orderedDescending
                        : result == .orderedAscending
                }
            }
            // 完全同分时按 id 排，保证结果可复现（`sorted` 本身不保证稳定）。
            return lhs.id < rhs.id
        }
    }

    /// 按单个排序字段比较两个条目。
    ///
    /// - Parameters:
    ///   - lhs: 左值。
    ///   - rhs: 右值。
    ///   - key: 排序字段。
    /// - Returns: 比较结果。
    private static func compare(_ lhs: MediaItem, _ rhs: MediaItem, by key: ItemSortBy) -> ComparisonResult {
        switch key {
        case .sortName, .name:
            return lhs.name.localizedStandardCompare(rhs.name)
        case .productionYear:
            return compareValues(lhs.productionYear ?? 0, rhs.productionYear ?? 0)
        case .communityRating:
            return compareValues(lhs.communityRating ?? 0, rhs.communityRating ?? 0)
        case .criticRating:
            return compareValues(lhs.communityRating ?? 0, rhs.communityRating ?? 0)
        case .dateCreated:
            return compareValues(lhs.dateCreated ?? .distantPast, rhs.dateCreated ?? .distantPast)
        case .premiereDate:
            return compareValues(lhs.premiereDate ?? .distantPast, rhs.premiereDate ?? .distantPast)
        case .runtime:
            return compareValues(lhs.runTime ?? .zero, rhs.runTime ?? .zero)
        case .playCount:
            return compareValues(lhs.userData.playCount, rhs.userData.playCount)
        case .datePlayed:
            return compareValues(
                lhs.userData.lastPlayedDate ?? .distantPast,
                rhs.userData.lastPlayedDate ?? .distantPast
            )
        case .random:
            // 演示模式用固定种子做「伪随机」，保证同一个查询每次结果一致。
            return compareValues(
                DemoArtwork.stableHash(lhs.id),
                DemoArtwork.stableHash(rhs.id)
            )
        default:
            return lhs.name.localizedStandardCompare(rhs.name)
        }
    }

    /// 比较两个 `Comparable` 值。
    ///
    /// - Parameters:
    ///   - lhs: 左值。
    ///   - rhs: 右值。
    /// - Returns: 比较结果。
    private static func compareValues<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    /// 按 `StartIndex` / `Limit` 切页。
    ///
    /// - Parameters:
    ///   - items: 已排序的完整结果。
    ///   - startIndex: 起点（已保证 ≥ 0）。
    ///   - limit: 每页条数；`nil` 或 ≤ 0 表示不截断。
    /// - Returns: 本页条目。
    private func paginate(_ items: [MediaItem], startIndex: Int, limit: Int?) -> [MediaItem] {
        let total = items.count
        let lower = min(startIndex, total)
        guard let limit, limit > 0 else {
            return lower == 0 ? items : Array(items[lower...])
        }
        let upper = min(lower + limit, total)
        return Array(items[lower..<upper])
    }
}
