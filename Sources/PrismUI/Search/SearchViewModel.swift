import Foundation
import Observation
import PrismCore

// MARK: - 数据源契约

/// 搜索接口的原始响应。
///
/// 服务端把电影 / 剧集 / 单集 / 人物混在一个列表里返回，这里保留原样：
/// **分组是视图模型的事**（可测、可改排序），数据源只负责「把服务器的字节变成模型」。
public struct SearchResponse: Sendable, Equatable {
    /// 媒体条目（电影 / 剧集 / 单集，可能混有服务端新增的类型）。
    public let items: [MediaItem]

    /// 人物。既可以是数据源单独查出来的，也可以是 ``items`` 里 `Type == Person` 的条目。
    public let people: [Person]

    /// 服务端报告的总命中数（`TotalRecordCount`）。
    ///
    /// 单页最多返回 `limit` 条，所以「结果数」不能拿本页条数冒充：搜索「沙丘」
    /// 命中 137 条时，界面曾经显示「共 60 个结果」。
    public let totalCount: Int?

    /// 创建响应。
    ///
    /// - Parameters:
    ///   - items: 媒体条目。
    ///   - people: 人物。
    ///   - totalCount: 服务端总命中数；`nil` 表示数据源没提供。
    public init(items: [MediaItem] = [], people: [Person] = [], totalCount: Int? = nil) {
        self.items = items
        self.people = people
        self.totalCount = totalCount
    }

    /// 是否没有任何结果。
    public var isEmpty: Bool {
        items.isEmpty && people.isEmpty
    }
}

/// 搜索数据源。
///
/// 只做一件事：给定关键词，返回原始结果。**不负责**防抖、取消、分组、排序、
/// 最近搜索——那些都在 ``SearchViewModel`` 里，因为它们与 UI 状态强相关。
///
/// 要求 `Sendable`：搜索会脱离主线程执行，实现方不得持有非线程安全状态
/// （`EmbyClient` 是 actor，天然满足）。
///
/// ```swift
/// struct MockSearchDataSource: SearchDataSource {
///     func search(_ term: String, limit: Int) async throws -> SearchResponse {
///         SearchResponse(items: [movie, series], people: [actor])
///     }
/// }
/// ```
public protocol SearchDataSource: Sendable {
    /// 按关键词搜索。
    ///
    /// - Parameters:
    ///   - term: 关键词（已由视图模型去掉首尾空白）。
    ///   - limit: 建议返回的最大条数。
    /// - Returns: 原始结果。
    /// - Throws: ``PrismCore/EmbyError``；取消时抛 ``PrismCore/EmbyError/cancelled``
    ///   或 `CancellationError`，视图模型会把这两种情况静默忽略。
    func search(_ term: String, limit: Int) async throws -> SearchResponse
}

public extension SearchDataSource {
    /// 按默认条数搜索（60 条，与 ``ItemsQuery/search(_:)`` 的预设一致）。
    ///
    /// - Parameter term: 关键词。
    /// - Returns: 原始结果。
    /// - Throws: ``PrismCore/EmbyError``。
    func search(_ term: String) async throws -> SearchResponse {
        try await search(term, limit: 60)
    }
}

/// 搜索结果的图片地址提供者。
///
/// 视图层不掌握服务器基址，也不该自己拼 `/Items/{id}/Images/Primary`；
/// 数据源知道基址，因此由它额外提供图片地址。
///
/// 拆成独立协议（而不是塞进 ``SearchDataSource``）的原因：预览 / 测试用的假数据源
/// 通常不需要真实图片，可以只实现搜索本身。
public protocol SearchImageProviding: Sendable {
    /// 解析条目的图片地址。
    ///
    /// - Parameters:
    ///   - id: 条目 / 人物 id。
    ///   - tag: 服务端给的图片 tag；`nil` 或空串表示没有该图片。
    ///   - maxWidth: 期望的最大宽度（pt），用于让服务器返回合适档位。
    /// - Returns: 可直接交给 ``SwiftUI/AsyncPosterImage`` 的地址；没有图片时为 `nil`。
    func imageURL(for id: String, kind: ImageKind, tag: String?, maxWidth: Int) -> URL?
}

public extension SearchImageProviding {
    func imageURL(for id: String, tag: String?, maxWidth: Int) -> URL? {
        imageURL(for: id, kind: .primary, tag: tag, maxWidth: maxWidth)
    }
}

// MARK: - 结果分组

/// 分组后的搜索结果。
///
/// 分组顺序固定为 **电影 → 剧集 → 单集 → 人物**，与
/// `docs/research/ux-benchmark.md` §S14 的「结果页分组」一致；每组内部有稳定排序，
/// 保证同一关键词多次搜索的顺序不会跳。
public struct SearchResults: Sendable, Equatable {
    /// 电影。
    public let movies: [MediaItem]

    /// 剧集。
    public let series: [MediaItem]

    /// 单集。
    public let episodes: [MediaItem]

    /// 人物。
    public let people: [Person]

    /// 直接按分组创建（预览 / 测试用）。
    ///
    /// - Parameters:
    ///   - movies: 电影。
    ///   - series: 剧集。
    ///   - episodes: 单集。
    ///   - people: 人物。
    ///   - serverTotalCount: 服务端总命中数；`nil` 表示未知。
    public init(
        movies: [MediaItem] = [],
        series: [MediaItem] = [],
        episodes: [MediaItem] = [],
        people: [Person] = [],
        serverTotalCount: Int? = nil
    ) {
        self.movies = movies
        self.series = series
        self.episodes = episodes
        self.people = people
        self.serverTotalCount = serverTotalCount
    }

    /// 按原始响应分组。
    ///
    /// 规则：
    /// - 按 `Type` 归类，`Person` 转成 ``PrismCore/Person``（Emby 的搜索会把人物当成
    ///   普通条目返回，图片仍在 `ImageTags.Primary` 里）；
    /// - 未知类型（`BoxSet` / `Video` / 服务端新增类型）在 v1.0 不展示，避免出现
    ///   「点开是空壳」的条目；
    /// - 排序：电影 / 剧集按名称（本地化比较），单集按「剧名 → 季 → 集」。
    ///
    /// - Parameter response: 数据源返回的原始结果。
    public init(response: SearchResponse) {
        var movies: [MediaItem] = []
        var series: [MediaItem] = []
        var episodes: [MediaItem] = []
        var people: [Person] = response.people

        for item in response.items {
            switch item.type {
            case .movie:
                movies.append(item)
            case .series:
                series.append(item)
            case .episode:
                episodes.append(item)
            case .person:
                people.append(
                    Person(
                        id: item.id,
                        name: item.name,
                        role: nil,
                        type: item.type.rawValue,
                        primaryImageTag: item.primaryImageTag
                    )
                )
            default:
                continue
            }
        }

        self.movies = movies.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        self.series = series.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        self.episodes = episodes.sorted { lhs, rhs in
            let lhsSeries = lhs.seriesName ?? ""
            let rhsSeries = rhs.seriesName ?? ""
            if lhsSeries != rhsSeries {
                return lhsSeries.localizedStandardCompare(rhsSeries) == .orderedAscending
            }
            let lhsSeason = lhs.parentIndexNumber ?? 0
            let rhsSeason = rhs.parentIndexNumber ?? 0
            if lhsSeason != rhsSeason { return lhsSeason < rhsSeason }
            return (lhs.indexNumber ?? 0) < (rhs.indexNumber ?? 0)
        }
        self.people = people.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        self.serverTotalCount = response.totalCount
    }

    /// 是否一个结果都没有。
    public var isEmpty: Bool {
        movies.isEmpty && series.isEmpty && episodes.isEmpty && people.isEmpty
    }

    /// 本页已加载的结果总数（四组之和）。
    public var totalCount: Int {
        movies.count + series.count + episodes.count + people.count
    }

    /// 服务端报告的总命中数；`nil` 表示数据源没提供。
    public let serverTotalCount: Int?

    /// 是否还有未加载的结果（服务端总数大于本页条数）。
    ///
    /// 为 `true` 时界面显示「共 N+ 个结果」，避免把 60 条的分页上限说成总数。
    public var isTruncated: Bool {
        guard let serverTotalCount else { return false }
        return serverTotalCount > totalCount
    }

    /// 展示用的结果数文案。
    public var totalCountText: String {
        if isTruncated, let serverTotalCount {
            return "\(serverTotalCount)+"
        }
        return "\(totalCount)"
    }

    /// 媒体条目总数（不含人物）。
    public var mediaCount: Int {
        movies.count + series.count + episodes.count
    }
}

// MARK: - 最近搜索存储

/// 最近搜索的持久化（`UserDefaults`）。
///
/// 单独抽出来的原因：`UserDefaults` 由外部注入，测试与预览可以各用一套
/// `UserDefaults(suiteName:)`，不会污染真实偏好；去重、截断等规则也集中在这里，
/// 视图模型只负责调用。
///
/// 规则（`docs/research/ux-benchmark.md` §S14）：最多 ``maxCount`` 条、去重
/// （大小写不敏感）、最近搜的排最前。
public struct RecentSearchesStore {
    /// 默认的存储 key。
    public static let defaultKey = "app.prism.search.recentSearches"

    /// 最多保留多少条。
    public let maxCount: Int

    /// 底层存储。
    private let defaults: UserDefaults

    /// 存储 key。
    private let key: String

    /// 创建存储。
    ///
    /// - Parameters:
    ///   - defaults: 底层 `UserDefaults`，默认 `.standard`；测试传独立 suite。
    ///   - key: 存储 key，默认 ``defaultKey``。
    ///   - maxCount: 最多保留条数，默认 10（工单要求；UX 文档建议 8，这里按工单）。
    public init(
        defaults: UserDefaults = .standard,
        key: String = RecentSearchesStore.defaultKey,
        maxCount: Int = 10
    ) {
        self.defaults = defaults
        self.key = key
        self.maxCount = max(maxCount, 1)
    }

    /// 读取最近搜索（已去空、去重、截断）。
    ///
    /// - Returns: 最近搜索列表，最近的在最前。
    public func load() -> [String] {
        let stored = defaults.stringArray(forKey: key) ?? []
        var result: [String] = []
        for raw in stored {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            guard !result.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) else { continue }
            result.append(term)
            if result.count >= maxCount { break }
        }
        return result
    }

    /// 写回最近搜索。
    ///
    /// - Parameter terms: 完整列表（已排好序）。
    public func save(_ terms: [String]) {
        if terms.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(Array(terms.prefix(maxCount)), forKey: key)
        }
    }

    /// 把一条关键词插到列表最前（去重、截断），返回新列表。
    ///
    /// 纯函数，方便单测与预览。
    ///
    /// - Parameters:
    ///   - term: 新关键词。
    ///   - terms: 现有列表。
    /// - Returns: 更新后的列表；关键词为空时原样返回。
    public func inserting(_ term: String, into terms: [String]) -> [String] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return terms }
        var result = terms.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        result.insert(trimmed, at: 0)
        if result.count > maxCount {
            result.removeLast(result.count - maxCount)
        }
        return result
    }
}

// MARK: - 视图模型

/// 搜索视图模型。
///
/// 职责（`docs/research/ux-benchmark.md` §S14）：
/// - **防抖 300ms**：用 ``PrismCore/Debouncer`` 合并连续输入，不自己写 `Timer`；
/// - **取消**：新关键词到来时取消上一次请求（`Task` 取消传播到网络层），
///   并用「代次（generation）」丢弃迟到的旧结果，避免闪回；
/// - **分组**：电影 / 剧集 / 单集 / 人物（见 ``SearchResults``）；
/// - **最近搜索**：``RecentSearchesStore`` 持久化，最多 10 条、去重；
/// - **空查询**：`state == .idle`，界面显示最近搜索 + 热门推荐。
///
/// 线程：整个类在 `@MainActor`，网络调用在 `await` 处让出主线程；
/// `state` 只在主线程写入，视图可以直接读取。
///
/// ```swift
/// let viewModel = SearchViewModel(dataSource: EmbySearchDataSource(client: client, userId: id))
/// viewModel.query = "银翼"          // 300ms 后自动搜索
/// await viewModel.search("沙丘")    // 立即搜索（点最近搜索 / 重试）
/// ```
@MainActor
@Observable
public final class SearchViewModel {
    // MARK: 状态

    /// 当前加载状态。
    ///
    /// - `.idle`：还没输入（显示最近搜索 + 热门推荐）；
    /// - `.loading`：请求进行中（显示骨架屏）；
    /// - `.loaded`：有结果；
    /// - `.empty`：搜到了但一个结果都没有；
    /// - `.failed`：请求失败（可重试）。
    public private(set) var state: LoadState<SearchResults>

    /// 搜索框文本。
    ///
    /// 赋值后自动走 300ms 防抖；清空则立刻回到初始态（`.idle`）。
    /// 由工具栏搜索框（`NavigationModel.searchText`）或最近搜索点击驱动。
    public var query: String = "" {
        didSet {
            guard query != oldValue, !isApplyingProgrammaticQuery else { return }
            scheduleSearch()
        }
    }

    /// 最近搜索（最近的在前，最多 ``RecentSearchesStore/maxCount`` 条）。
    public private(set) var recentSearches: [String]

    /// 触发搜索所需的最短关键词长度。
    ///
    /// 默认 2，与 `docs/research/ux-benchmark.md` §S14「输入过短 → 至少输入 2 个字符」
    /// 一致；纯 CJK 场景若希望单字也搜，把这里改成 1 即可。
    public var minimumQueryLength: Int

    // MARK: 依赖

    /// 数据源。
    private let dataSource: any SearchDataSource

    /// 图片地址提供者；数据源同时实现了 ``SearchImageProviding`` 时自动取用。
    private let imageProvider: (any SearchImageProviding)?

    /// 最近搜索存储。
    private let recentStore: RecentSearchesStore

    /// 防抖器（``PrismCore/Debouncer``，actor）。
    private let debouncer: Debouncer

    /// 单次请求的最大条数。
    private let resultLimit: Int

    // MARK: 内部状态

    /// 代次：每次关键词变化自增，迟到的旧请求据此丢弃。
    private var generation = 0

    /// 程序化写入 `query`（``search(_:)``）时置位，避免重复触发防抖。
    private var isApplyingProgrammaticQuery = false

    // MARK: 初始化

    /// 创建视图模型。
    ///
    /// - Parameters:
    ///   - dataSource: 搜索数据源。
    ///   - imageProvider: 图片地址提供者；`nil` 时若数据源实现了
    ///     ``SearchImageProviding`` 则自动使用它。
    ///   - recentSearches: 最近搜索存储，默认 `UserDefaults.standard`。
    ///   - debounceInterval: 防抖间隔，默认 300ms。
    ///   - minimumQueryLength: 最短关键词长度，默认 2。
    ///   - resultLimit: 单次请求最大条数，默认 60。
    public init(
        dataSource: any SearchDataSource,
        imageProvider: (any SearchImageProviding)? = nil,
        recentSearches store: RecentSearchesStore = RecentSearchesStore(),
        debounceInterval: Duration = .milliseconds(300),
        minimumQueryLength: Int = 2,
        resultLimit: Int = 60
    ) {
        self.dataSource = dataSource
        self.imageProvider = imageProvider ?? (dataSource as? any SearchImageProviding)
        self.recentStore = store
        self.debouncer = Debouncer(interval: debounceInterval)
        self.minimumQueryLength = max(minimumQueryLength, 1)
        self.resultLimit = max(resultLimit, 1)
        self.state = .idle
        self.recentSearches = store.load()
    }

    // MARK: 派生状态

    /// 去掉首尾空白后的关键词。
    public var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 关键词是否为空（界面显示最近搜索 + 热门推荐）。
    public var isQueryEmpty: Bool {
        trimmedQuery.isEmpty
    }

    /// 关键词是否太短（界面提示「至少输入 N 个字符」）。
    public var isQueryTooShort: Bool {
        let term = trimmedQuery
        return !term.isEmpty && term.count < minimumQueryLength
    }

    /// 当前结果（仅 `.loaded` 时有值）。
    public var results: SearchResults? {
        state.value
    }

    /// 扁平化的结果列表，供键盘 ↑↓ 在**跨分组**的结果间连续移动。
    ///
    /// 顺序与界面显示顺序一致：电影 → 剧集 → 单集 → 人物。
    public var flatResults: [SearchResultItem] {
        guard let results else { return [] }
        return results.movies.map { resultItem(for: $0) }
            + results.series.map { resultItem(for: $0) }
            + results.episodes.map { resultItem(for: $0) }
            + results.people.map { resultItem(for: $0) }
    }

    // MARK: 动作

    /// 立即搜索（跳过防抖）。
    ///
    /// 用于「点击最近搜索」「错误重试」等**明确意图**的场合。执行后会记入最近搜索。
    ///
    /// - Parameter term: 关键词。
    public func search(_ term: String) async {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)

        generation &+= 1
        let currentGeneration = generation

        isApplyingProgrammaticQuery = true
        query = term
        isApplyingProgrammaticQuery = false

        // 丢掉还在防抖窗口里的待执行任务，避免重复请求。
        await debouncer.cancel()

        guard !trimmed.isEmpty, trimmed.count >= minimumQueryLength else {
            state = .idle
            return
        }

        await performSearch(term: trimmed, generation: currentGeneration)
    }

    /// 重试当前关键词（错误态的「重试」按钮）。
    public func retry() async {
        await search(trimmedQuery)
    }

    /// 清空最近搜索。
    public func clearRecent() {
        recentSearches = []
        recentStore.save([])
    }

    /// 删除一条最近搜索。
    ///
    /// - Parameter term: 要删除的关键词（大小写不敏感）。
    public func removeRecent(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recentSearches.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        recentStore.save(recentSearches)
    }

    /// 把关键词写回搜索框（不触发立即搜索），用于最近搜索点击时同步工具栏。
    ///
    /// - Parameter term: 关键词。
    public func setQueryWithoutSearch(_ term: String) {
        isApplyingProgrammaticQuery = true
        query = term
        isApplyingProgrammaticQuery = false
    }

    // MARK: 行模型

    /// 把媒体条目转成结果行模型（含已解析的海报地址）。
    ///
    /// - Parameter item: 媒体条目。
    /// - Returns: 行模型。
    public func resultItem(for item: MediaItem) -> SearchResultItem {
        let source = item.imageSource(for: .primary)
        return SearchResultItem(
            item: item,
            imageURL: imageProvider?.imageURL(
                for: source?.itemId ?? item.id,
                kind: source?.kind ?? .primary,
                tag: source?.tag,
                maxWidth: item.type == .episode ? 160 : 240
            )
        )
    }

    /// 把人物转成结果行模型（含已解析的头像地址）。
    ///
    /// - Parameter person: 人物。
    /// - Returns: 行模型。
    public func resultItem(for person: Person) -> SearchResultItem {
        SearchResultItem(
            person: person,
            imageURL: imageProvider?.imageURL(for: person.id, tag: person.primaryImageTag, maxWidth: 160)
        )
    }

    /// 海报网格用的图片地址（2:3 海报，360pt 宽足够 Retina）。
    ///
    /// - Parameter item: 媒体条目。
    /// - Returns: 地址；没有海报时为 `nil`。
    public func posterURL(for item: MediaItem) -> URL? {
        let source = item.imageSource(for: .primary)
        return imageProvider?.imageURL(
            for: source?.itemId ?? item.id,
            kind: source?.kind ?? .primary,
            tag: source?.tag,
            maxWidth: 360
        )
    }

    /// 人物头像地址。
    ///
    /// - Parameter person: 人物。
    /// - Returns: 地址；没有头像时为 `nil`。
    public func avatarURL(for person: Person) -> URL? {
        imageProvider?.imageURL(for: person.id, tag: person.primaryImageTag, maxWidth: 160)
    }

    // MARK: 防抖与请求

    /// 安排一次防抖搜索（`query` 的 `didSet` 调用）。
    ///
    /// 清空 / 过短时**同步**回到 `.idle`，让界面立刻切回初始态；同时仍向防抖器
    /// 投递一次空操作，用来取消正在进行的请求（`Debouncer` 会在新任务到来时
    /// 取消上一个任务，取消会传播到 `URLSession`）。
    private func scheduleSearch() {
        generation &+= 1
        let currentGeneration = generation
        let term = trimmedQuery

        if term.isEmpty || term.count < minimumQueryLength {
            state = .idle
        }

        let debouncer = self.debouncer
        Task { [weak self] in
            await debouncer.schedule { [weak self] in
                await self?.runSearch(term: term, generation: currentGeneration)
            }
        }
    }

    /// 防抖到点后的入口：二次校验关键词与代次，再真正发请求。
    ///
    /// - Parameters:
    ///   - term: 关键词。
    ///   - generation: 发起时的代次。
    private func runSearch(term: String, generation: Int) async {
        guard generation == self.generation else { return }
        guard !term.isEmpty, term.count >= minimumQueryLength else {
            state = .idle
            return
        }
        await performSearch(term: term, generation: generation)
    }

    /// 执行一次搜索并更新状态。
    ///
    /// 三重校验保证「迟到的旧结果」不会覆盖新结果：
    /// 1. `Task.isCancelled`：请求已被新输入取消；
    /// 2. 代次一致；
    /// 3. 当前关键词仍等于发起时的关键词。
    ///
    /// 「记入最近搜索」放在这里（而不是放在防抖回调里）：只有**真的发出请求**的关键词
    /// 才值得记住，这样中间敲的半个词不会污染列表；输入路径与
    /// ``search(_:)`` 路径也因此共用同一处逻辑。
    ///
    /// - Parameters:
    ///   - term: 关键词。
    ///   - generation: 发起时的代次。
    private func performSearch(term: String, generation: Int) async {
        guard generation == self.generation, trimmedQuery == term else { return }

        state = .loading
        remember(term)

        do {
            let response = try await dataSource.search(term, limit: resultLimit)
            guard !Task.isCancelled else { return }
            guard generation == self.generation, trimmedQuery == term else { return }

            let results = SearchResults(response: response)
            state = results.isEmpty ? .empty : .loaded(results)
        } catch is CancellationError {
            // 被新关键词取代：保留现有画面，等新请求的结果。
        } catch let error as EmbyError where error == .cancelled {
            // 同上：取消不是错误，不展示错误态。
        } catch let error as EmbyError {
            guard generation == self.generation else { return }
            state = .failed(error)
        } catch {
            guard generation == self.generation else { return }
            state = .failed(.unknown(String(describing: error)))
        }
    }

    /// 记入最近搜索。
    ///
    /// - Parameter term: 已去空白的关键词。
    private func remember(_ term: String) {
        let updated = recentStore.inserting(term, into: recentSearches)
        guard updated != recentSearches else { return }
        recentSearches = updated
        recentStore.save(updated)
    }
}

// MARK: - 预览支持

extension SearchViewModel {
    /// 直接构造一个指定状态的视图模型，**仅供 `#Preview` 与演示模式**。
    ///
    /// 正常路径永远通过 ``query`` / ``search(_:)`` 驱动；这个入口只是为了让预览能
    /// 一次展示「加载 / 有结果 / 无结果 / 错误」四态，不需要真的跑网络。
    ///
    /// - Parameters:
    ///   - state: 预置状态。
    ///   - query: 预置关键词。
    ///   - recentSearches: 预置最近搜索。
    ///   - dataSource: 数据源，默认 ``InertSearchDataSource``。
    ///   - imageProvider: 图片地址提供者，默认 `nil`（显示占位图）。
    /// - Returns: 视图模型。
    internal convenience init(
        previewState state: LoadState<SearchResults>,
        query: String = "",
        recentSearches: [String] = [],
        dataSource: any SearchDataSource = InertSearchDataSource(),
        imageProvider: (any SearchImageProviding)? = nil
    ) {
        self.init(
            dataSource: dataSource,
            imageProvider: imageProvider,
            recentSearches: RecentSearchesStore(
                defaults: UserDefaults(suiteName: "app.prism.preview") ?? .standard,
                maxCount: 10
            )
        )
        self.setQueryWithoutSearch(query)
        self.state = state
        self.recentSearches = recentSearches
    }
}

/// 永远返回空结果的数据源，用于预览与「没有接入服务器」的兜底。
public struct InertSearchDataSource: SearchDataSource {
    /// 创建数据源。
    public init() {}

    /// 永远返回空结果。
    ///
    /// - Parameters:
    ///   - term: 关键词（忽略）。
    ///   - limit: 条数（忽略）。
    /// - Returns: 空响应。
    /// - Throws: 不会抛出。
    public func search(_ term: String, limit: Int) async throws -> SearchResponse {
        SearchResponse()
    }
}
