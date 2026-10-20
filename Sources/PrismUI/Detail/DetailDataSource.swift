import EmbyAPI
import Foundation
import PrismCore

// MARK: - 数据源协议

/// 详情页需要的全部数据能力。
///
/// 这是一层**注入点**：详情页本身不认识 `EmbyClient`，只认识这七个方法。
///
/// - 真实实现：``EmbyDetailDataSource``（把方法映射到 `EmbyClient` 的
///   `itemDetail` / `seasons` / `episodes` / `similar` / `markPlayed` / `markFavorite`）；
/// - 预览实现：`DetailPreviewData.swift` 里的 `PreviewDetailDataSource`；
/// - 演示模式 / 测试：由上层提供自己的实现（本目录不依赖演示数据）。
///
/// 协议要求 `Sendable`：``DetailViewModel`` 会并发拉取详情、季集与相似内容，
/// 实现会被多个子任务同时持有，因此实现内部的可变状态必须自己保证线程安全
/// （`EmbyClient` 是 actor，天然满足）。
///
/// ```swift
/// let dataSource = EmbyDetailDataSource(client: client, userId: session.userId,
///                                       accessToken: session.accessToken)
/// let model = DetailViewModel(dataSource: dataSource, itemId: "abc")
/// await model.load()
/// ```
public protocol DetailDataSource: Sendable {
    /// 单条目详情（含 `People` / `MediaSources`）。
    ///
    /// - Parameter itemId: 条目 id。
    /// - Returns: 条目。
    /// - Throws: ``PrismCore/EmbyError``。
    func itemDetail(itemId: String) async throws -> MediaItem

    /// 某剧的季列表。
    ///
    /// - Parameter seriesId: 剧集 id。
    /// - Returns: 季数组（服务端顺序，调用方负责排序）。
    /// - Throws: ``PrismCore/EmbyError``。
    func seasons(seriesId: String) async throws -> [MediaItem]

    /// 某剧的集列表。
    ///
    /// - Parameters:
    ///   - seriesId: 剧集 id。
    ///   - seasonId: 季 id；`nil` 表示**全部季**（详情页首次加载时需要它来定位默认季）。
    /// - Returns: 集数组。
    /// - Throws: ``PrismCore/EmbyError``。
    func episodes(seriesId: String, seasonId: String?) async throws -> [MediaItem]

    /// 相似内容。
    ///
    /// - Parameter itemId: 条目 id。
    /// - Returns: 相似条目数组。
    /// - Throws: ``PrismCore/EmbyError``。
    func similar(itemId: String) async throws -> [MediaItem]

    /// 标记已看 / 未看。
    ///
    /// - Parameters:
    ///   - itemId: 条目 id。
    ///   - played: `true` 标记已看。
    /// - Returns: 服务端返回的最新用户数据（用于覆盖本地乐观更新）。
    /// - Throws: ``PrismCore/EmbyError``。
    func setPlayed(itemId: String, played: Bool) async throws -> UserItemData

    /// 收藏 / 取消收藏。
    ///
    /// - Parameters:
    ///   - itemId: 条目 id。
    ///   - isFavorite: `true` 收藏。
    /// - Returns: 服务端返回的最新用户数据（用于覆盖本地乐观更新）。
    /// - Throws: ``PrismCore/EmbyError``。
    func setFavorite(itemId: String, isFavorite: Bool) async throws -> UserItemData

    /// 生成一张图片的地址。
    ///
    /// 详情页要的图比列表页多（backdrop / logo / thumb / 人物头像），因此这里以
    /// **条目 id + 图片类型 + 缓存 tag** 为参数，而不是直接收一个 `MediaItem`：
    /// 演职员头像的 id 属于 `Person`，并不属于 `MediaItem`。
    ///
    /// - Parameters:
    ///   - itemId: 条目 id（人物头像传 `Person/id`，Emby 把人物也存成 item）。
    ///   - kind: 图片类型。
    ///   - tag: 缓存 tag；`nil` 时实现方可以返回 `nil`（没有 tag 必然 404）。
    ///   - maxWidth: 期望宽度（服务端等比缩放）。
    /// - Returns: 图片地址；无法生成时为 `nil`，UI 会显示占位图。
    func imageURL(itemId: String, kind: ImageKind, tag: String?, maxWidth: Int) -> URL?
}

// MARK: - Emby 实现

/// ``DetailDataSource`` 的真实实现：把详情页的七个能力映射到 `EmbyClient`。
///
/// 只做「端点 + 参数」的组合，不做重试 / 缓存 / 状态机——那些属于网络层与视图模型。
///
/// ```swift
/// let dataSource = EmbyDetailDataSource(client: client, userId: "u1", accessToken: token)
/// ```
public struct EmbyDetailDataSource: DetailDataSource {
    private let client: EmbyClient
    private let userId: String
    private let accessToken: String?
    private let similarLimit: Int

    /// 创建 Emby 数据源。
    ///
    /// - Parameters:
    ///   - client: 已登录的客户端（令牌由 `EmbyClient` 自己持有）。
    ///   - userId: 当前用户 id（`/Users/{id}/…` 端点必填）。
    ///   - accessToken: 访问令牌，**只用于拼图片 URL 的 `?api_key=`**，默认 `nil`。
    ///     条目 / 季集 / 相似等 JSON 请求由 `EmbyClient` 自己注入鉴权头，不需要它。
    ///
    ///     **什么时候要传**：只有当注入的图片加载器是 `PassthroughImageLoader`
    ///     （裸 `URLSession`，不发任何请求头）时才需要。
    ///     App 内的默认加载器 `EmbyImageLoader` 会把**同源** URL 识别成
    ///     `ImageURLEndpoint` 并交给 `EmbyClient` 发请求，鉴权头由客户端注入，
    ///     因此传 `nil` 即可——这样令牌不会出现在 URL、缓存键与日志里。
    ///   - similarLimit: 相似推荐条数，默认 12。
    public init(
        client: EmbyClient,
        userId: String,
        accessToken: String? = nil,
        similarLimit: Int = 12
    ) {
        self.client = client
        self.userId = userId
        self.accessToken = accessToken
        self.similarLimit = similarLimit
    }

    /// 取条目详情（转发到 `EmbyClient.itemDetail`）。
    public func itemDetail(itemId: String) async throws -> MediaItem {
        try await client.itemDetail(userId: userId, itemId: itemId)
    }

    /// 取季列表（转发到 `EmbyClient.seasons`）。
    public func seasons(seriesId: String) async throws -> [MediaItem] {
        try await client.seasons(seriesId: seriesId, userId: userId)
    }

    /// 取集列表（`seasonId` 为 `nil` 时取全部季）。
    public func episodes(seriesId: String, seasonId: String?) async throws -> [MediaItem] {
        try await client.episodes(seriesId: seriesId, userId: userId, seasonId: seasonId)
    }

    /// 取相似推荐（条数由 `similarLimit` 决定）。
    public func similar(itemId: String) async throws -> [MediaItem] {
        try await client.similar(userId: userId, itemId: itemId, limit: similarLimit)
    }

    /// 标记已看 / 未看（转发到 `EmbyClient.markPlayed`）。
    public func setPlayed(itemId: String, played: Bool) async throws -> UserItemData {
        try await client.markPlayed(userId: userId, itemId: itemId, played: played)
    }

    /// 收藏 / 取消收藏（转发到 `EmbyClient.markFavorite`）。
    public func setFavorite(itemId: String, isFavorite: Bool) async throws -> UserItemData {
        try await client.markFavorite(userId: userId, itemId: itemId, favorite: isFavorite)
    }

    /// 拼图片地址。
    ///
    /// 复用 `EmbyAPI` 的 ``EmbyAPI/ImageEndpoint``（负责路径与 `maxWidth` / `tag` 参数）
    /// 与 ``EmbyAPI/RequestBuilder/joinedURL(baseURL:path:query:)``（负责基址拼接、
    /// 反代前缀与百分号编码），不自己拼字符串。
    ///
    /// - Important: 只有在 `accessToken` 非空时才会附加 `api_key`。
    ///   附加后令牌会出现在 URL、`URLCache` 键与服务端访问日志里，
    ///   因此**默认不附加**：App 内用 `EmbyImageLoader` 时它走的是带鉴权头的
    ///   `ImageURLEndpoint` 路径，根本不需要 `api_key`。
    public func imageURL(itemId: String, kind: ImageKind, tag: String?, maxWidth: Int) -> URL? {
        guard !itemId.isEmpty else { return nil }
        guard let tag, !tag.isEmpty else { return nil }

        let endpoint = ImageEndpoint(itemId: itemId, kind: kind, tag: tag, maxWidth: maxWidth)
        var query = endpoint.query
        if let accessToken, !accessToken.isEmpty {
            query["api_key"] = accessToken
        }
        return try? RequestBuilder.joinedURL(
            baseURL: client.baseURL,
            path: endpoint.path,
            query: query
        )
    }
}
