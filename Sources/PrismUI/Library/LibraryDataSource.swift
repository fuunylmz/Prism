import EmbyAPI
import Foundation
import PrismCore

// MARK: - 数据源协议

/// 媒体库网格的数据来源。
///
/// **为什么要有这层协议**：``LibraryViewModel`` 需要能在 `#Preview` 与单元测试里
/// 完全离线运行，而 `EmbyClient` 是 actor 且强绑定真实网络。协议把「取一页条目」
/// 这一个动作抽出来，生产实现是 ``EmbyLibraryDataSource``，预览实现是
/// `LibraryPreviewDataSource`（`LibraryPreviewSupport.swift`）。
///
/// 方法签名对齐 `Sources/EmbyAPI/Endpoints/EmbyClient+Library.swift` 的
/// `items(userId:query:)`，但**去掉了 `userId`**：用户 id 属于「连接身份」，
/// 在构造 ``EmbyLibraryDataSource`` 时就已经固定，不应该每次翻页都让调用方重复传。
///
/// 协议要求 `Sendable`：它会被 ``LibraryViewModel`` 持有，而 VM 在 `@MainActor` 上，
/// 数据源的实现内部可能持有 `EmbyClient`（actor，本身 `Sendable`）。
public protocol LibraryDataSource: Sendable {
    /// 取一页条目。
    ///
    /// - Parameter query: 已构造好的查询（含分页、排序、筛选）。
    /// - Returns: 本页条目与**过滤后**的总数。
    /// - Throws: ``PrismCore/EmbyError``。
    func items(query: ItemsQuery) async throws -> ItemsQueryResult

    /// 标记已看 / 未看。
    ///
    /// - Parameters:
    ///   - itemId: 条目 id。
    ///   - played: `true` 标记已看，`false` 标记未看。
    /// - Returns: 服务端更新后的用户数据。
    /// - Throws: ``PrismCore/EmbyError``。
    func markPlayed(itemId: String, played: Bool) async throws -> UserItemData

    /// 收藏 / 取消收藏。
    ///
    /// - Parameters:
    ///   - itemId: 条目 id。
    ///   - favorite: `true` 收藏，`false` 取消收藏。
    /// - Returns: 服务端更新后的用户数据。
    /// - Throws: ``PrismCore/EmbyError``。
    func markFavorite(itemId: String, favorite: Bool) async throws -> UserItemData

    /// 拼一张海报的绝对地址。
    ///
    /// 视图层只认识 `URL?`（见 ``PrismUI/AsyncPosterImage``），
    /// 「`/Items/{id}/Images/Primary?tag=…`」这类 Emby 细节必须留在数据层。
    ///
    /// - Parameters:
    ///   - item: 条目。
    ///   - kind: 图片类型。
    ///   - maxWidth: 期望宽度（pt，服务端按比例缩放）。
    /// - Returns: 可交给图片加载器的地址；该条目没有这种图时为 `nil`。
    func imageURL(for item: MediaItem, kind: ImageKind, maxWidth: Int) -> URL?
}

// MARK: - Emby 实现

/// 走真实 Emby 服务器的数据源。
///
/// ```swift
/// let dataSource = EmbyLibraryDataSource(
///     client: client,
///     userId: session.userId,
///     baseURL: server.baseURL,
///     accessToken: session.accessToken
/// )
/// let viewModel = LibraryViewModel(dataSource: dataSource, libraryId: view.id, kind: .video)
/// ```
///
/// ## 关于 `accessToken`
///
/// `DesignSystem` 的 ``PrismUI/PosterImageLoading`` 只接受 `URL`（不带请求头），
/// 而 `EmbyClient` 不对外暴露令牌。因此海报地址需要把令牌放进 `?api_key=`，
/// 这是 Emby 官方支持的图片鉴权方式（`/Items/{id}/Images/{type}?api_key=…`）。
/// 传 `nil` 时不加该参数（匿名可读的服务器、或将来换成带请求头的 Nuke 加载器）。
///
/// **不要把 `accessToken` 写进日志**：``PrismCore/Redactor`` 会自动脱敏
/// `api_key`，本类型也不打印 URL。
public struct EmbyLibraryDataSource: LibraryDataSource {
    /// Emby 客户端。
    private let client: EmbyClient

    /// 当前用户 id（写进鉴权头与 `/Users/{id}/Items` 路径）。
    private let userId: String

    /// 服务器基地址（拼图片地址用，支持 `/emby` 反代前缀）。
    private let baseURL: URL

    /// 访问令牌；`nil` 表示海报地址不带 `api_key`。
    private let accessToken: String?

    /// 创建数据源。
    ///
    /// - Parameters:
    ///   - client: Emby 客户端。
    ///   - userId: 当前用户 id。
    ///   - baseURL: 服务器基地址。
    ///   - accessToken: 访问令牌（用于海报地址的 `api_key`），默认 `nil`。
    public init(
        client: EmbyClient,
        userId: String,
        baseURL: URL,
        accessToken: String? = nil
    ) {
        self.client = client
        self.userId = userId
        self.baseURL = baseURL
        self.accessToken = accessToken
    }

    public func items(query: ItemsQuery) async throws -> ItemsQueryResult {
        try await client.items(userId: userId, query: query)
    }

    public func markPlayed(itemId: String, played: Bool) async throws -> UserItemData {
        try await client.markPlayed(userId: userId, itemId: itemId, played: played)
    }

    public func markFavorite(itemId: String, favorite: Bool) async throws -> UserItemData {
        try await client.markFavorite(userId: userId, itemId: itemId, favorite: favorite)
    }

    public func imageURL(for item: MediaItem, kind: ImageKind, maxWidth: Int) -> URL? {
        guard let tag = item.imageTags[kind], !tag.isEmpty else { return nil }

        var query: [String: String] = [
            "tag": tag,
            "maxWidth": String(maxWidth),
            "quality": "90"
        ]
        if let accessToken, !accessToken.isEmpty {
            query["api_key"] = accessToken
        }

        let path = "/Items/\(item.id)/Images/\(kind.rawValue)"
        // `joinedURL` 是纯函数，只在基址非法时抛错（构造时已经校验过），
        // 因此这里用 `try?` 退化为占位图，而不是把错误抛给视图层。
        return try? RequestBuilder.joinedURL(baseURL: baseURL, path: path, query: query)
    }
}
