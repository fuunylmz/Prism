import Foundation
import PrismCore

/// 把端点串成业务语义的高层便利方法。
///
/// 这些方法只是「端点 + 解码类型」的组合，不做重试 / 缓存 / 状态机
/// （那些属于 `PrismData` 与 UI 层）。放在 `EmbyAPI` 里是为了让上层少写
/// `try await client.send(SomeEndpoint(...))` 这类样板代码。
///
/// 所有方法都在 `EmbyClient` 这个 actor 上，因此天然串行化令牌读取。
public extension EmbyClient {

    // MARK: - 连接与认证

    /// 探测服务器公开信息（连接校验第一枪，不需要 token）。
    ///
    /// - Returns: 服务器名 / 版本 / id / 地址。
    /// - Throws: ``PrismCore/EmbyError``。
    func publicInfo() async throws -> PublicServerInfo {
        try await send(PublicSystemInfoEndpoint())
    }

    /// 用户名 + 密码登录。
    ///
    /// 成功后会把令牌与用户 id 写进客户端（等价于再调一次
    /// ``EmbyClient/setSession(_:)``），后续请求自动带鉴权头。
    ///
    /// - Parameters:
    ///   - username: 用户名。
    ///   - password: 明文密码（必须走 HTTPS）。
    /// - Returns: 可持久化的 ``PrismCore/AuthSession``。
    /// - Throws: ``PrismCore/EmbyError/unauthorized`` 表示用户名或密码错误。
    func authenticate(username: String, password: String) async throws -> AuthSession {
        let result: AuthenticationResult = try await send(
            AuthenticateEndpoint(username: username, password: password)
        )
        let session = result.asSession
        setSession(session)
        return session
    }

    /// 取当前 token 对应的用户（App 启动时恢复会话用）。
    ///
    /// - Important: `/Users/Me` 在 Emby 侧存在性存疑（见 ``CurrentUserEndpoint`` 的说明）。
    ///   本地保存了 `userId` 时，优先用 ``user(id:)``；本方法适合 Jellyfin，
    ///   或在拿到 5xx 后回退。
    /// - Returns: 当前用户。
    /// - Throws: ``PrismCore/EmbyError/unauthorized`` 表示 token 已被吊销，应跳回登录页。
    func currentUser() async throws -> EmbyUser {
        try await send(CurrentUserEndpoint())
    }

    /// 按 id 取用户（恢复会话的稳妥方案）。
    ///
    /// `GET /Users/{Id}` 在 Emby 官方 Reference 与 OpenAPI 中均存在，
    /// 是 `/Users/Me` 不可用时的回退。
    ///
    /// - Parameter userId: 用户 id（来自本地保存的 ``PrismCore/AuthSession``）。
    /// - Returns: 用户。
    /// - Throws: ``PrismCore/EmbyError``。
    func user(id userId: String) async throws -> EmbyUser {
        try await send(UserByIdEndpoint(userId: userId))
    }

    /// 登出并吊销当前 token。
    ///
    /// 成功后清空本地令牌与用户 id。
    ///
    /// - Throws: ``PrismCore/EmbyError``。网络失败时**仍会**清空本地状态
    ///   （用户意图是登出，不能因为网络问题把人卡在登录态）。
    func logout() async throws {
        do {
            try await send(LogoutEndpoint())
        } catch {
            setSession(nil)
            throw error
        }
        setSession(nil)
    }

    // MARK: - 媒体库

    /// 顶层媒体库列表。
    ///
    /// - Parameters:
    ///   - userId: 用户 id。
    ///   - includeExternalContent: 是否包含 channels / 直播电视等外部视图。
    /// - Returns: 媒体库视图数组（带 `CollectionType`）。
    /// - Throws: ``PrismCore/EmbyError``。
    func views(userId: String, includeExternalContent: Bool? = nil) async throws -> [MediaView] {
        let result: ViewsQueryResult = try await send(
            ViewsEndpoint(userId: userId, includeExternalContent: includeExternalContent)
        )
        return result.items
    }

    /// 列表查询（浏览 / 搜索 / 筛选 / 分页）。
    ///
    /// - Parameters:
    ///   - userId: 用户 id。
    ///   - query: 查询参数。
    /// - Returns: 分页结果。
    /// - Throws: ``PrismCore/EmbyError``。
    func items(userId: String, query: ItemsQuery = ItemsQuery()) async throws -> ItemsQueryResult {
        try await send(ItemsEndpoint(userId: userId, query: query))
    }

    /// 「继续观看」。
    ///
    /// - Parameters:
    ///   - userId: 用户 id。
    ///   - limit: 条数。
    /// - Returns: 有播放进度但未看完的条目。
    /// - Throws: ``PrismCore/EmbyError``。
    func resume(userId: String, limit: Int = 20) async throws -> [MediaItem] {
        let result: ItemsQueryResult = try await send(
            ResumeEndpoint(userId: userId, limit: limit)
        )
        return result.items
    }

    /// 「最新添加」。
    ///
    /// - Parameters:
    ///   - userId: 用户 id。
    ///   - parentId: 限定媒体库。
    ///   - limit: 条数（该端点不支持分页）。
    ///   - includeItemTypes: 限定类型。
    ///   - groupItems: 是否按容器聚合。
    /// - Returns: 条目数组（服务端返回的是裸数组，没有总数）。
    /// - Throws: ``PrismCore/EmbyError``。
    func latest(
        userId: String,
        parentId: String? = nil,
        limit: Int = 20,
        includeItemTypes: [ItemType] = [],
        groupItems: Bool? = nil
    ) async throws -> [MediaItem] {
        try await send(
            LatestEndpoint(
                userId: userId,
                parentId: parentId,
                limit: limit,
                includeItemTypes: includeItemTypes,
                groupItems: groupItems
            )
        )
    }

    /// 「接下来看什么」（下一集）。
    ///
    /// - Parameters:
    ///   - userId: 用户 id。
    ///   - seriesId: 限定某剧。
    ///   - limit: 条数。
    /// - Returns: 条目数组。
    /// - Throws: ``PrismCore/EmbyError``。
    func nextUp(userId: String, seriesId: String? = nil, limit: Int = 24) async throws -> [MediaItem] {
        let result: ItemsQueryResult = try await send(
            NextUpEndpoint(userId: userId, seriesId: seriesId, limit: limit)
        )
        return result.items
    }

    /// 单条目详情（返回全量字段，含 `People` / `MediaSources`）。
    ///
    /// - Parameters:
    ///   - userId: 用户 id。
    ///   - itemId: 条目 id。
    /// - Returns: 条目。
    /// - Throws: ``PrismCore/EmbyError``。
    func itemDetail(userId: String, itemId: String) async throws -> MediaItem {
        try await send(ItemDetailEndpoint(userId: userId, itemId: itemId))
    }

    /// 某剧的集列表。
    ///
    /// - Parameters:
    ///   - seriesId: 剧集 id。
    ///   - userId: 用户 id（带上才有 `UserData`）。
    ///   - seasonId: 季 id；`nil` 表示全部季。
    /// - Returns: 集数组。
    /// - Throws: ``PrismCore/EmbyError``。
    func episodes(seriesId: String, userId: String? = nil, seasonId: String? = nil) async throws -> [MediaItem] {
        let result: ItemsQueryResult = try await send(
            EpisodesEndpoint(seriesId: seriesId, userId: userId, seasonId: seasonId)
        )
        return result.items
    }

    /// 某剧的季列表。
    ///
    /// - Parameters:
    ///   - seriesId: 剧集 id。
    ///   - userId: 用户 id。
    /// - Returns: 季数组。
    /// - Throws: ``PrismCore/EmbyError``。
    func seasons(seriesId: String, userId: String? = nil) async throws -> [MediaItem] {
        let result: ItemsQueryResult = try await send(
            SeasonsEndpoint(seriesId: seriesId, userId: userId)
        )
        return result.items
    }

    /// 相似内容。
    ///
    /// - Parameters:
    ///   - userId: 用户 id。
    ///   - itemId: 条目 id。
    ///   - limit: 条数。
    /// - Returns: 相似条目数组。
    /// - Throws: ``PrismCore/EmbyError``。
    func similar(userId: String, itemId: String, limit: Int = 12) async throws -> [MediaItem] {
        let result: ItemsQueryResult = try await send(
            SimilarEndpoint(itemId: itemId, userId: userId, limit: limit)
        )
        return result.items
    }

    // MARK: - 播放协商

    /// 播放协商：拿媒体源、`PlaySessionId` 与播放 URL。
    ///
    /// - Parameters:
    ///   - itemId: 条目 id。
    ///   - userId: 用户 id。
    ///   - profile: 客户端能力描述；默认 ``DeviceProfile/prismMacOS(maxStreamingBitrate:)``。
    ///   - startTimeTicks: 起播位置（续播时传）。
    ///   - mediaSourceId: 指定媒体源（多版本时）。
    /// - Returns: 协商结果。
    /// - Throws: ``PrismCore/EmbyError``。
    func playbackInfo(
        itemId: String,
        userId: String,
        profile: DeviceProfile = .prismMacOS(),
        startTimeTicks: Ticks? = nil,
        mediaSourceId: String? = nil
    ) async throws -> PlaybackInfoResponse {
        try await send(
            PlaybackInfoEndpoint(
                itemId: itemId,
                userId: userId,
                profile: profile,
                startTimeTicks: startTimeTicks,
                mediaSourceId: mediaSourceId
            )
        )
    }

    // MARK: - 图片

    /// 取条目图片字节。
    ///
    /// 缓存策略为 `.returnCacheDataElseLoad`：`URLCache` 命中时不会回服务器。
    /// 调用前请先确认条目上确实有对应 tag，否则必然 404。
    ///
    /// - Parameters:
    ///   - itemId: 条目 id。
    ///   - kind: 图片类型。
    ///   - tag: 缓存 tag（来自 `ImageTags` / `BackdropImageTags`）。
    ///   - maxWidth: 最大宽度。
    ///   - maxHeight: 最大高度。
    ///   - index: 图片序号（`Backdrop` / `Chapter` 多图时必填）。
    /// - Returns: 图片原始字节。
    /// - Throws: ``PrismCore/EmbyError/notFound`` 表示该图不存在。
    func imageData(
        itemId: String,
        kind: ImageKind,
        tag: String? = nil,
        maxWidth: Int? = nil,
        maxHeight: Int? = nil,
        index: Int? = nil
    ) async throws -> Data {
        try await data(
            ImageEndpoint(
                itemId: itemId,
                kind: kind,
                index: index,
                tag: tag,
                maxWidth: maxWidth,
                maxHeight: maxHeight
            )
        )
    }

    // MARK: - 用户数据

    /// 标记已看 / 未看。
    ///
    /// - Parameters:
    ///   - userId: 用户 id。
    ///   - itemId: 条目 id。
    ///   - played: `true` 标记已看，`false` 标记未看。
    /// - Returns: 服务端更新后的用户数据。
    /// - Throws: ``PrismCore/EmbyError``。
    func markPlayed(userId: String, itemId: String, played: Bool) async throws -> UserItemData {
        try await send(MarkPlayedEndpoint(userId: userId, itemId: itemId, isPlayed: played))
    }

    /// 收藏 / 取消收藏。
    ///
    /// - Parameters:
    ///   - userId: 用户 id。
    ///   - itemId: 条目 id。
    ///   - favorite: `true` 收藏，`false` 取消收藏。
    /// - Returns: 服务端更新后的用户数据。
    /// - Throws: ``PrismCore/EmbyError``。
    func markFavorite(userId: String, itemId: String, favorite: Bool) async throws -> UserItemData {
        try await send(MarkFavoriteEndpoint(userId: userId, itemId: itemId, isFavorite: favorite))
    }

    // MARK: - 进度上报

    /// 开始播放上报（`POST /Sessions/Playing`）。
    ///
    /// - Parameter report: 上报内容。
    /// - Throws: ``PrismCore/EmbyError``。
    func reportStart(_ report: PlaybackProgressReport) async throws {
        try await send(PlayingStartEndpoint(report: report))
    }

    /// 播放进度上报（`POST /Sessions/Playing/Progress`）。
    ///
    /// 建议每 10 秒一次 + 每次用户交互后立即一次。
    ///
    /// - Parameter report: 上报内容。
    /// - Throws: ``PrismCore/EmbyError``。
    func reportProgress(_ report: PlaybackProgressReport) async throws {
        try await send(PlayingProgressEndpoint(report: report))
    }

    /// 停止播放上报（`POST /Sessions/Playing/Stopped`）。
    ///
    /// - Parameter report: 上报内容。
    /// - Throws: ``PrismCore/EmbyError``。
    func reportStopped(_ report: PlaybackStopReport) async throws {
        try await send(PlayingStoppedEndpoint(report: report))
    }
}
