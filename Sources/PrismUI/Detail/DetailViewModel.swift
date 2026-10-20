import Foundation
import Observation
import PrismCore

// MARK: - 详情内容

/// 详情页一次加载完成的全部数据。
///
/// 由 ``DetailViewModel`` 组装：电影只有 `item` / `similar` / `people`，
/// 剧集额外带上 `seasons` 与「当前季」的 `episodes`。
///
/// 结构体不可变（全部 `let`）：切换季、切换已看状态都通过 ``DetailViewModel``
/// 生成新实例，视图因此永远看到一份自洽的快照，不会出现「标题是 A 季、列表是 B 季」。
public struct DetailContent: Sendable, Equatable {
    /// 条目本身（电影 / 剧集 / 单集）。
    public let item: MediaItem
    /// 季列表；电影为空数组。
    public let seasons: [MediaItem]
    /// 当前季的集（按集号升序）；电影为空数组。
    public let episodes: [MediaItem]
    /// 相似推荐。
    public let similar: [MediaItem]
    /// 演职员（导演 / 编剧优先，其次演员）。
    public let people: [Person]

    /// 创建详情内容。
    ///
    /// - Parameters:
    ///   - item: 条目本身。
    ///   - seasons: 季列表，默认空。
    ///   - episodes: 当前季的集，默认空。
    ///   - similar: 相似推荐，默认空。
    ///   - people: 演职员，默认空。
    public init(
        item: MediaItem,
        seasons: [MediaItem] = [],
        episodes: [MediaItem] = [],
        similar: [MediaItem] = [],
        people: [Person] = []
    ) {
        self.item = item
        self.seasons = seasons
        self.episodes = episodes
        self.similar = similar
        self.people = people
    }

    // MARK: 派生信息

    /// 是否为剧集（决定用哪套布局）。
    public var isSeries: Bool {
        item.type == .series
    }

    /// 当前季里「下一集未看」；整季看完为 `nil`。
    ///
    /// 集列表已按集号升序，所以「第一个未看的」就是接下来的那一集。
    public var nextUpEpisode: MediaItem? {
        episodes.first { !$0.userData.played }
    }

    /// 当前季已看集数。
    public var watchedEpisodeCount: Int {
        episodes.filter { $0.userData.played }.count
    }

    /// 主播放按钮的语义。
    ///
    /// 把「播放 / 继续 / 重看 / 继续观看 S2E5 / 重新观看 S1E1」这五种文案的**判定**
    /// 放在模型里，视图只负责把结果翻译成本地化文案。
    public enum PrimaryPlayback: Sendable, Equatable {
        /// 首次播放。
        case play
        /// 有进度，从上次位置继续。
        case resume(Ticks)
        /// 已看完，从头重看。
        case rewatch
        /// 剧集：继续看下一集未看。
        case continueEpisode(MediaItem)
        /// 剧集：全部看完，从第一集重看。
        case restartSeries(MediaItem)
    }

    /// 当前的主播放语义。
    public var primaryPlayback: PrimaryPlayback {
        if isSeries {
            if let next = nextUpEpisode {
                return .continueEpisode(next)
            }
            if let first = episodes.first {
                return .restartSeries(first)
            }
            // 剧集但一集都没有：没有可播目标，视图会把主按钮禁用。
            return .play
        }
        if item.userData.played {
            return .rewatch
        }
        if item.userData.playbackPosition.rawValue > 0 {
            return .resume(item.userData.playbackPosition)
        }
        return .play
    }

    /// 主播放按钮要播放的条目；剧集没有集时为 `nil`（按钮禁用）。
    public var primaryPlaybackItem: MediaItem? {
        switch primaryPlayback {
        case let .continueEpisode(episode), let .restartSeries(episode):
            return episode
        case .play, .rewatch, .resume:
            return isSeries ? nil : item
        }
    }

    /// 主播放的起播位置：已看完从 0 开始（重看），否则沿用上次进度。
    public var primaryResumePosition: Ticks {
        guard let target = primaryPlaybackItem else { return .zero }
        return target.userData.played ? .zero : target.userData.playbackPosition
    }

    /// 「S2E5」式紧凑编号（UX 文档用这种写法）；信息不全时为 `nil`。
    ///
    /// - Parameter episode: 单集。
    /// - Returns: 编号字符串。
    public func episodeCode(for episode: MediaItem) -> String? {
        guard let season = episode.parentIndexNumber, let index = episode.indexNumber else {
            return nil
        }
        return "S\(season)E\(index)"
    }

    // MARK: 内部变换

    /// 返回一个只替换了某一集用户数据的新内容。
    ///
    /// 乐观更新与回滚都走这里：`item` / `seasons` / `episodes` / `similar` 里
    /// 同 id 的条目一起改，避免「按钮说已看、列表还说没看」。
    ///
    /// - Parameters:
    ///   - userData: 新的用户数据。
    ///   - itemID: 要替换的条目 id。
    /// - Returns: 新内容。
    func replacingUserData(_ userData: UserItemData, for itemID: String) -> DetailContent {
        DetailContent(
            item: item.id == itemID ? item.withUserData(userData) : item,
            seasons: seasons.map { $0.id == itemID ? $0.withUserData(userData) : $0 },
            episodes: episodes.map { $0.id == itemID ? $0.withUserData(userData) : $0 },
            similar: similar.map { $0.id == itemID ? $0.withUserData(userData) : $0 },
            people: people
        )
    }

    /// 返回一个只替换了当前季集列表的新内容。
    ///
    /// 按「级联」语义把已看状态刷到整部剧的集与季上。
    ///
    /// Emby 对 `Series` / `Season` 标记已看会连带所有集，但本地只替换同 id 的条目
    /// （集与剧的 id 不同）。不同步的后果：头部按钮变成「已看」，下面集列表仍是
    /// 全未看、仍写着「继续观看 S1E1」。
    ///
    /// - Parameter played: 是否已看。
    /// - Returns: 新内容。
    func replacingPlayedCascade(_ played: Bool) -> DetailContent {
        DetailContent(
            item: item,
            seasons: seasons.map { $0.withPlayed(played) },
            episodes: episodes.map { $0.withPlayed(played) },
            similar: similar,
            people: people
        )
    }

    /// - Parameter episodes: 新的集列表。
    /// - Returns: 新内容。
    func replacingEpisodes(_ episodes: [MediaItem]) -> DetailContent {
        DetailContent(
            item: item,
            seasons: seasons,
            episodes: episodes,
            similar: similar,
            people: people
        )
    }
}

// MARK: - 播放请求

/// 详情页发起播放时交给外壳的请求。
///
/// 字段与 ``PrismUI/Route/player(itemId:mediaSourceId:resumeAt:)`` 一一对应，
/// 外壳拿到后直接构造路由即可，不需要再回到详情页取数据。
public struct DetailPlaybackRequest: Sendable, Equatable {
    /// 要播放的条目 id。
    public let itemId: String
    /// 指定媒体源；`nil` 表示由播放器协商。
    public let mediaSourceId: String?
    /// 起播位置（续播点）；新片为 ``PrismCore/Ticks/zero``。
    public let resumeAt: Ticks

    /// 创建播放请求。
    ///
    /// - Parameters:
    ///   - itemId: 条目 id。
    ///   - mediaSourceId: 媒体源 id，默认 `nil`。
    ///   - resumeAt: 起播位置，默认 0。
    public init(itemId: String, mediaSourceId: String? = nil, resumeAt: Ticks = .zero) {
        self.itemId = itemId
        self.mediaSourceId = mediaSourceId
        self.resumeAt = resumeAt
    }
}

// MARK: - 出站动作

/// 详情页向外抛出的动作。
///
/// 详情页不持有导航与播放器：播放、打开别的条目都由外壳注入。这样详情页在
/// `#Preview` 里可以完全独立运行，也不会反向依赖 `AppShell` 的导航模型。
///
/// ```swift
/// MovieDetailView(
///     model: model,
///     actions: DetailActions(
///         play: { request in navigation.openPlayer(request) },
///         openItem: { id in navigation.showDetail(id) }
///     )
/// )
/// ```
public struct DetailActions {
    /// 播放某条目。
    public var play: (DetailPlaybackRequest) -> Void
    /// 打开另一个条目的详情（相似推荐、演职员点进去）。
    public var openItem: (String) -> Void

    /// 创建动作集合。
    ///
    /// - Parameters:
    ///   - play: 播放回调，默认什么都不做。
    ///   - openItem: 打开条目回调，默认什么都不做。
    public init(
        play: @escaping (DetailPlaybackRequest) -> Void = { _ in },
        openItem: @escaping (String) -> Void = { _ in }
    ) {
        self.play = play
        self.openItem = openItem
    }
}

// MARK: - 视图模型

/// 条目详情的视图模型（电影 / 剧集共用）。
///
/// 职责：
/// - 拉取详情、季、集、相似与演职员，组装成一份 ``DetailContent``；
/// - **定位剧集的默认季**（见 ``defaultSeasonID(seasons:allEpisodes:)``）；
/// - 切换季（优先用已缓存的集，避免重复请求）；
/// - 已看 / 收藏的**乐观更新**：先改 UI，失败回滚并暴露 ``actionError``。
///
/// 并发：整个类型在 `@MainActor` 上，视图可直接读写；网络等待点在 `await` 处让出。
/// 重复调用 ``load()`` 时用「代数」丢弃过期响应，避免慢请求覆盖新结果。
@MainActor
@Observable
public final class DetailViewModel {
    // MARK: 公开状态

    /// 当前加载状态。
    public private(set) var state: LoadState<DetailContent>

    /// 当前选中的季 id；电影为 `nil`。
    ///
    /// 由 ``load()`` 自动定位到「下一集未看」所在的季，用户点季选择器时改写。
    public var selectedSeasonId: String?

    /// 是否正在拉取某一季的集（季切换的网络等待）。
    public private(set) var isLoadingEpisodes = false

    /// 是否正在提交「已看」切换（按钮据此禁用，防止连点）。
    public private(set) var isUpdatingPlayed = false

    /// 是否正在提交「收藏」切换。
    public private(set) var isUpdatingFavorite = false

    /// 最近一次用户动作的错误。
    ///
    /// 详情内容本身仍然可用（乐观更新已回滚），所以不用把整页变成错误态；
    /// 视图可以用一行提示或 toast 呈现它。
    public private(set) var actionError: EmbyError?

    /// 条目 id。
    public let itemId: String

    // MARK: 私有状态

    /// 数据源。
    private let dataSource: any DetailDataSource

    /// 全部季的集（首次加载时一次取回，供默认季定位与季切换复用）。
    private var allEpisodes: [MediaItem] = []

    /// 加载代数：每次 `load()` 自增，用来丢弃过期响应。
    private var loadGeneration = 0

    // MARK: 初始化

    /// 创建视图模型。
    ///
    /// - Parameters:
    ///   - dataSource: 数据源（真实实现或预览实现）。
    ///   - itemId: 条目 id。
    public init(dataSource: any DetailDataSource, itemId: String) {
        self.dataSource = dataSource
        self.itemId = itemId
        self.state = .idle
    }

    /// 预览专用：直接注入一个状态，不发起任何请求。
    ///
    /// `#Preview` 需要「加载中 / 错误」这类瞬时状态，而公开 API 只能通过 ``load()``
    /// 得到。配合 ``loadIfNeeded()``（只从 `.idle` 出发）就能静态展示任意一态。
    ///
    /// - Parameters:
    ///   - previewState: 初始状态。
    ///   - dataSource: 图片地址来源，默认预览数据源。
    ///   - selectedSeasonId: 预选季 id；`nil` 时取内容的第一季。
    init(
        previewState: LoadState<DetailContent>,
        dataSource: any DetailDataSource = PreviewDetailDataSource(),
        selectedSeasonId: String? = nil
    ) {
        self.dataSource = dataSource
        self.itemId = previewState.value?.item.id ?? "preview"
        self.state = previewState
        let content = previewState.value
        self.allEpisodes = content?.episodes ?? []
        self.selectedSeasonId = selectedSeasonId ?? content?.seasons.first?.id
    }

    // MARK: 加载

    /// 首次进入时加载；已处于加载中 / 已加载 / 已失败时**不重复请求**。
    ///
    /// 视图用 `.task { await model.loadIfNeeded() }` 调用它，因此预览里注入的
    /// `.loading` / `.failed` 状态不会被立刻覆盖。
    public func loadIfNeeded() async {
        // `.failed` 也要重试：`.task` 在条目切换、详情栏重新出现时都会触发，
        // 若把失败当成「已有结果」直接返回，用户会被永久钉在错误页上。
        switch state {
        case .idle, .failed:
            await load()
        case .loading, .loaded, .empty:
            return
        }
    }

    /// 重新加载详情。
    ///
    /// 季 / 集 / 相似是**可选信息**：它们失败时只降级为空数组，详情主体仍然展示
    /// （用户至少能看到标题、简介与演职员，而不是整页报错）。详情本身失败才进入
    /// `.failed`。
    public func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        actionError = nil
        state = .loading

        do {
            let item = try await dataSource.itemDetail(itemId: itemId)

            var seasons: [MediaItem] = []
            var allEpisodes: [MediaItem] = []
            if item.type == .series {
                async let seasonsRequest = dataSource.seasons(seriesId: item.id)
                async let episodesRequest = dataSource.episodes(seriesId: item.id, seasonId: nil)
                seasons = ((try? await seasonsRequest) ?? []).sorted(by: Self.seasonOrder)
                allEpisodes = ((try? await episodesRequest) ?? []).sorted(by: Self.episodeOrder)
            }

            async let similarRequest = dataSource.similar(itemId: item.id)
            let similar = (try? await similarRequest) ?? []

            guard generation == loadGeneration else { return }

            self.allEpisodes = allEpisodes
            let seasonID = Self.defaultSeasonID(seasons: seasons, allEpisodes: allEpisodes)
            selectedSeasonId = seasonID

            // 季列表拉取失败但集拉到了：仍把集显示出来（否则用户会看到「该季暂无剧集」
            // 的假空态），此时没有季可选，集列表就是全部集。
            let seasonEpisodes = seasons.isEmpty
                ? allEpisodes
                : Self.episodes(in: Self.season(withID: seasonID, in: seasons), from: allEpisodes)

            state = .loaded(
                DetailContent(
                    item: item,
                    seasons: seasons,
                    episodes: seasonEpisodes,
                    similar: similar,
                    people: Self.orderedPeople(item.people ?? [])
                )
            )
        } catch is CancellationError {
            // 视图消失导致的取消：不要把页面永久卡在骨架屏上。
            guard generation == loadGeneration, state == .loading else { return }
            state = .idle
        } catch {
            guard generation == loadGeneration else { return }
            state = .failed(Self.normalized(error))
        }
    }

    // MARK: 切换季

    /// 切换季。
    ///
    /// 优先用 ``load()`` 时缓存下来的集（切换是瞬时的、不闪骨架屏）；缓存里没有
    /// 这一季的集时才走一次网络（例如服务端首次只返回了部分季）。
    ///
    /// - Parameter seasonId: 目标季 id。
    public func selectSeason(_ seasonId: String) async {
        guard case let .loaded(content) = state else { return }
        guard seasonId != selectedSeasonId else { return }
        guard content.seasons.contains(where: { $0.id == seasonId }) else { return }

        let previousSeasonID = selectedSeasonId
        selectedSeasonId = seasonId

        let cached = Self.episodes(
            in: Self.season(withID: seasonId, in: content.seasons),
            from: allEpisodes
        )
        if !cached.isEmpty {
            state = .loaded(content.replacingEpisodes(cached))
            return
        }

        isLoadingEpisodes = true
        defer { isLoadingEpisodes = false }

        do {
            let fetched = try await dataSource
                .episodes(seriesId: content.item.id, seasonId: seasonId)
                .sorted(by: Self.episodeOrder)

            allEpisodes = Self.merging(episodes: allEpisodes, with: fetched)

            // 期间用户可能又切了季或整页重载，只有仍停在这一季时才落盘。
            guard case let .loaded(latest) = state, selectedSeasonId == seasonId else { return }
            state = .loaded(latest.replacingEpisodes(fetched))
        } catch {
            actionError = Self.normalized(error)
            // 回滚选中季，避免「高亮在 B 季、列表还是 A 季」的错位。
            if selectedSeasonId == seasonId {
                selectedSeasonId = previousSeasonID
            }
        }
    }

    // MARK: 已看 / 收藏

    /// 切换「已看」。
    ///
    /// **乐观更新**：先翻转本地状态让 UI 立即响应，再提交；失败回滚到调用前的快照，
    /// 并把错误放进 ``actionError``。成功后用服务端返回的用户数据覆盖本地值
    /// （服务端可能同时把播放进度清零，本地猜不出来）。
    public func togglePlayed() async {
        guard case let .loaded(content) = state, !isUpdatingPlayed else { return }

        let previous = content
        let target = !content.item.userData.played
        isUpdatingPlayed = true
        actionError = nil
        defer { isUpdatingPlayed = false }

        var optimistic = content.item.userData
        optimistic.played = target
        state = .loaded(content.replacingUserData(optimistic, for: content.item.id))

        do {
            let server = try await dataSource.setPlayed(itemId: content.item.id, played: target)
            guard case let .loaded(latest) = state else { return }
            var updated = latest.replacingUserData(server, for: content.item.id)
            // 剧集 / 季：服务端会级联到所有集，本地也要跟着刷，否则集列表与
            // 「已看 N 集」的计数都停在旧值。
            if content.isSeries {
                updated = updated.replacingPlayedCascade(target)
            }
            state = .loaded(updated)
        } catch {
            state = .loaded(previous)
            actionError = Self.normalized(error)
        }
    }

    /// 切换「收藏」。
    ///
    /// 与 ``togglePlayed()`` 相同的乐观更新 + 失败回滚策略。
    public func toggleFavorite() async {
        guard case let .loaded(content) = state, !isUpdatingFavorite else { return }

        let previous = content
        let target = !content.item.userData.isFavorite
        isUpdatingFavorite = true
        actionError = nil
        defer { isUpdatingFavorite = false }

        var optimistic = content.item.userData
        optimistic.isFavorite = target
        state = .loaded(content.replacingUserData(optimistic, for: content.item.id))

        do {
            let server = try await dataSource.setFavorite(itemId: content.item.id, isFavorite: target)
            guard case let .loaded(latest) = state else { return }
            state = .loaded(latest.replacingUserData(server, for: content.item.id))
        } catch {
            state = .loaded(previous)
            actionError = Self.normalized(error)
        }
    }

    /// 清除最近一次动作错误（视图关闭提示条后调用）。
    public func clearActionError() {
        actionError = nil
    }

    // MARK: 图片地址

    /// 详情头图地址：优先 backdrop（16:9 剧照），没有时退回海报。
    ///
    /// - Parameter item: 条目。
    /// - Returns: 地址；都没有时为 `nil`（头图会退化成纯色 + 标题）。
    public func headerImageURL(for item: MediaItem) -> URL? {
        imageURL(for: item, kind: .backdrop, maxWidth: 1600)
            ?? imageURL(for: item, kind: .primary, maxWidth: 1200)
    }

    /// 标题 logo 地址（透明 PNG）；没有 logo 时返回 `nil`，头图改用文字标题。
    ///
    /// - Parameter item: 条目。
    /// - Returns: 地址。
    public func logoImageURL(for item: MediaItem) -> URL? {
        imageURL(for: item, kind: .logo, maxWidth: 800)
    }

    /// 海报地址（2:3）。
    ///
    /// - Parameters:
    ///   - item: 条目。
    ///   - maxWidth: 期望宽度，默认 360（Retina 下约 180pt 卡片）。
    /// - Returns: 地址。
    public func posterImageURL(for item: MediaItem, maxWidth: Int = 360) -> URL? {
        imageURL(for: item, kind: .primary, maxWidth: maxWidth)
    }

    /// 集缩略图地址（16:9）：优先 `Thumb`，没有时退回 `Primary`。
    ///
    /// - Parameter item: 单集。
    /// - Returns: 地址。
    public func thumbnailImageURL(for item: MediaItem) -> URL? {
        imageURL(for: item, kind: .thumb, maxWidth: 640)
            ?? imageURL(for: item, kind: .primary, maxWidth: 640)
    }

    /// 演职员头像地址。
    ///
    /// Emby 把人物也存成 item，因此头像走同一套 `/Items/{id}/Images/{kind}` 端点。
    ///
    /// - Parameter person: 演职员。
    /// - Returns: 地址；没有头像时为 `nil`（UI 显示姓名首字）。
    public func avatarImageURL(for person: Person) -> URL? {
        dataSource.imageURL(
            itemId: person.id,
            kind: .primary,
            tag: person.primaryImageTag,
            maxWidth: 200
        )
    }

    /// 通用图片地址（转发给数据源）。
    ///
    /// - Parameters:
    ///   - item: 条目。
    ///   - kind: 图片类型。
    ///   - maxWidth: 期望宽度。
    /// - Returns: 地址。
    public func imageURL(for item: MediaItem, kind: ImageKind, maxWidth: Int) -> URL? {
        dataSource.imageURL(
            itemId: item.id,
            kind: kind,
            tag: Self.tag(for: item, kind: kind),
            maxWidth: maxWidth
        )
    }

    // MARK: 纯函数（默认季定位等）

    /// 剧集的默认季。
    ///
    /// **这是 UX 文档 §S08 强调的难点**：进详情页时不能总停在第一季，
    /// 用户要的是「我看到第几季第几集了」。规则：
    ///
    /// 1. 按（季号, 集号）升序找**第一集未看**的；
    /// 2. 取它所在的季作为默认季（优先用 `episode.seasonId`，缺失时按
    ///    `parentIndexNumber` 与季的 `indexNumber` 匹配——服务端两个字段都可能缺）；
    /// 3. 全部看完 → 选**最后一季**（用户刚看完的就是最后一季，方便回看）；
    /// 4. 一集都没有 → 选第一季（空季比「没有选中的季」更好，至少季选择器有高亮）。
    ///
    /// **特别篇（季号 0）不参与定位**：Emby 把花絮、特辑、番外放进 `Season 0`，
    /// 用户说「我看到第几季了」时指的是正片。若把特别篇算进来，只要有一集未看的
    /// 花絮，进页面就会跳到「特别篇」——这正是 UX 文档警告的那种「导航做错了」。
    /// 只有整部剧的正片都看完（或压根没有正片）时，才会回落到最后一季。
    ///
    /// - Parameters:
    ///   - seasons: 季列表（任意顺序）。
    ///   - allEpisodes: **全部季**的集（任意顺序）。
    /// - Returns: 默认季 id；没有季时为 `nil`。
    nonisolated static func defaultSeasonID(seasons: [MediaItem], allEpisodes: [MediaItem]) -> String? {
        let sortedSeasons = seasons.sorted(by: seasonOrder)
        guard !sortedSeasons.isEmpty else { return nil }
        guard !allEpisodes.isEmpty else { return sortedSeasons.first?.id }

        let nextUnwatched = allEpisodes
            .filter { !$0.userData.played && $0.parentIndexNumber != 0 }
            .sorted(by: episodeOrder)
            .first

        if let nextUnwatched, let seasonID = seasonID(for: nextUnwatched, in: sortedSeasons) {
            return seasonID
        }
        // 正片全看完（或未看的那一集找不到对应季）→ 最后一季。
        return sortedSeasons.last?.id
    }

    /// 某一集所属的季 id。
    ///
    /// - Parameters:
    ///   - episode: 单集。
    ///   - seasons: 季列表。
    /// - Returns: 季 id；无法匹配时为 `nil`。
    nonisolated static func seasonID(for episode: MediaItem, in seasons: [MediaItem]) -> String? {
        if let seasonID = episode.seasonId,
           seasons.contains(where: { $0.id == seasonID }) {
            return seasonID
        }
        guard let number = episode.parentIndexNumber else { return nil }
        return seasons.first { $0.indexNumber == number }?.id
    }

    /// 从全部集里筛出某一季的集，按集号升序。
    ///
    /// 优先按 `episode.seasonId` 匹配（Emby 的 `/Shows/{id}/Episodes` 稳定返回该字段）；
    /// 个别服务端 / 插件不返回 `SeasonId` 时，退回用 `parentIndexNumber` 与季的
    /// `indexNumber` 比对，避免出现「默认季定位到了、列表却是空的」。
    ///
    /// - Parameters:
    ///   - season: 目标季；`nil` 时返回空数组。
    ///   - episodes: 全部集。
    /// - Returns: 该季的集。
    nonisolated static func episodes(in season: MediaItem?, from episodes: [MediaItem]) -> [MediaItem] {
        guard let season else { return [] }
        let filtered = episodes.filter { episode in
            if let episodeSeasonID = episode.seasonId, !episodeSeasonID.isEmpty {
                return episodeSeasonID == season.id
            }
            guard let number = episode.parentIndexNumber, let seasonNumber = season.indexNumber else {
                return false
            }
            return number == seasonNumber
        }
        return filtered.sorted(by: episodeOrder)
    }

    /// 按 id 找季。
    ///
    /// - Parameters:
    ///   - seasonID: 季 id；`nil` 时返回 `nil`。
    ///   - seasons: 季列表。
    /// - Returns: 季。
    nonisolated static func season(withID seasonID: String?, in seasons: [MediaItem]) -> MediaItem? {
        guard let seasonID else { return nil }
        return seasons.first { $0.id == seasonID }
    }

    /// 把新拉到的集合并进缓存（同 id 覆盖，其余保留）。
    ///
    /// - Parameters:
    ///   - existing: 现有缓存。
    ///   - fetched: 新拉到的集。
    /// - Returns: 合并后的缓存。
    nonisolated static func merging(episodes existing: [MediaItem], with fetched: [MediaItem]) -> [MediaItem] {
        guard !fetched.isEmpty else { return existing }
        var byID: [String: MediaItem] = [:]
        for episode in existing {
            byID[episode.id] = episode
        }
        for episode in fetched {
            byID[episode.id] = episode
        }
        return byID.values.sorted(by: episodeOrder)
    }

    /// 季排序：按季号升序，特别篇（季号 0）排最前；缺季号排最后。
    ///
    /// - Parameters:
    ///   - lhs: 左。
    ///   - rhs: 右。
    /// - Returns: 是否升序。
    nonisolated static func seasonOrder(_ lhs: MediaItem, _ rhs: MediaItem) -> Bool {
        (lhs.indexNumber ?? Int.max) < (rhs.indexNumber ?? Int.max)
    }

    /// 集排序：先季号再集号；缺号排最后。
    ///
    /// - Parameters:
    ///   - lhs: 左。
    ///   - rhs: 右。
    /// - Returns: 是否升序。
    nonisolated static func episodeOrder(_ lhs: MediaItem, _ rhs: MediaItem) -> Bool {
        let leftSeason = lhs.parentIndexNumber ?? Int.max
        let rightSeason = rhs.parentIndexNumber ?? Int.max
        if leftSeason != rightSeason { return leftSeason < rightSeason }
        return (lhs.indexNumber ?? Int.max) < (rhs.indexNumber ?? Int.max)
    }

    /// 演职员排序：导演 → 编剧 → 演员 → 其他，同类保持服务端顺序。
    ///
    /// UX 文档 §S07 要求「导演 / 主演」优先出现，而 Emby 的 `People` 是混合数组。
    ///
    /// - Parameter people: 原始演职员。
    /// - Returns: 排序后的数组。
    nonisolated static func orderedPeople(_ people: [Person]) -> [Person] {
        people.enumerated()
            .sorted { lhs, rhs in
                let left = personRank(lhs.element)
                let right = personRank(rhs.element)
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
    }

    /// 演职员的展示优先级。
    ///
    /// - Parameter person: 演职员。
    /// - Returns: 越小越靠前。
    private nonisolated static func personRank(_ person: Person) -> Int {
        switch person.type?.lowercased() {
        case "director": 0
        case "writer", "screenplay": 1
        case "actor": 2
        case nil, "": 3
        default: 4
        }
    }

    /// 取条目上对应图片类型的缓存 tag。
    ///
    /// - Parameters:
    ///   - item: 条目。
    ///   - kind: 图片类型。
    /// - Returns: tag；没有该类型图片时为 `nil`。
    nonisolated static func tag(for item: MediaItem, kind: ImageKind) -> String? {
        switch kind {
        case .primary: item.primaryImageTag
        case .backdrop: item.primaryBackdropTag
        case .thumb: item.thumbImageTag
        case .logo: item.logoImageTag
        default: item.imageTags[kind]
        }
    }

    /// 把任意错误归一化成 ``PrismCore/EmbyError``。
    ///
    /// 数据源实现通常已经抛 `EmbyError`，但协议不强制；UI 层只认这一种错误类型。
    ///
    /// - Parameter error: 原始错误。
    /// - Returns: 归一化后的错误。
    nonisolated static func normalized(_ error: any Error) -> EmbyError {
        if let emby = error as? EmbyError { return emby }
        if error is CancellationError { return .cancelled }
        return .unknown(String(describing: error))
    }
}

// MARK: - MediaItem 副本

extension MediaItem {
    /// 返回一个只替换了用户数据的副本。
    ///
    /// `MediaItem` 的字段全部是 `let`（解码时一次性填好），而乐观更新需要
    /// 「同一份数据、只改 `userData`」。PrismCore 没有提供 copy-with，所以这里
    /// 用公开初始化器重建一份——放在 `Detail` 内部（不扩大模块公共 API），
    /// 只服务详情页的已看 / 收藏切换。
    ///
    /// 返回一个只把「已看」状态改成 `played` 的副本。
    ///
    /// 用于剧集级联：对整部剧标记已看时，服务端会把所有集一起标记，
    /// 本地集列表也要同步（否则「已看 0 集」「继续观看 S1E1」都不变）。
    ///
    /// - Parameter played: 是否已看。
    /// - Returns: 副本。
    func withPlayed(_ played: Bool) -> MediaItem {
        var data = userData
        data.played = played
        if played {
            data.playbackPosition = .zero
            data.unplayedItemCount = 0
        }
        return withUserData(data)
    }

    /// - Parameter userData: 新的用户数据。
    /// - Returns: 副本。
    func withUserData(_ userData: UserItemData) -> MediaItem {
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
