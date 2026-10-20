import EmbyAPI
import Foundation
import PrismCore

// MARK: - Emby 数据源

/// 基于 Emby `/Users/{userId}/Items` 的搜索数据源。
///
/// ## 为什么只用一次请求
///
/// Emby 的 `Items` 端点支持 `SearchTerm`，并且会把人物（`Type == Person`）当成普通条目
/// 一起返回——人物也有 `ImageTags.Primary`。因此电影 / 剧集 / 单集 / 人物可以**一次查完**，
/// 不需要额外打 `/Persons`（Emby 也没有这个端点）。
///
/// 请求参数取 ``ItemsQuery/search(_:)`` 的预设，并显式收紧三点：
/// - `includeItemTypes` 只保留 `Movie` / `Series` / `Episode` / `Person`（v1.0 不展示合集）；
/// - `limit` 由视图模型给出（默认 60，避免一次拉回整个库）；
/// - 只取 `Primary` 图，`imageTypeLimit = 1`，减少响应体积。
///
/// ## 图片地址与鉴权（已知缺口）
///
/// ``SearchImageProviding`` 返回的是普通 `https://…/Items/{id}/Images/Primary?tag=…`
/// 地址，交给 ``SwiftUI/AsyncPosterImage`` 用 `URLSession` 直连。Emby 默认要求图片也带
/// 鉴权，而图片加载器不带 `X-Emby-Token` 头——因此这里支持把令牌作为 `api_key`
/// 查询参数拼进 URL（Emby Web 客户端也是这么做的）。
///
/// - Important: `apiKey` 由宿主动传入（`EmbyClient` 不暴露令牌）。不传时，若服务器
///   禁止匿名取图，海报会显示占位图；这是图片层（`PosterImageLoading`）需要统一解决的问题，
///   不在搜索模块内绕过。
public struct EmbySearchDataSource: SearchDataSource, SearchImageProviding {
    /// 网络客户端。
    private let client: EmbyClient

    /// 当前用户 id（`/Users/{userId}/Items` 的路径参数）。
    private let userId: String

    /// 可选的图片令牌；拼进图片 URL 的 `api_key`。
    private let apiKey: String?

    /// 服务器基地址（图片 URL 用）。
    private let baseURL: URL

    /// 创建数据源。
    ///
    /// - Parameters:
    ///   - client: Emby 客户端（actor，天然 `Sendable`）。
    ///   - userId: 当前用户 id。
    ///   - apiKey: 图片令牌；`nil` 表示不带 `api_key`。
    ///   - baseURL: 服务器基地址（拼图片 URL 用）；`nil` 时取 ``EmbyClient/baseURL``。
    ///     外壳通常显式传入 `server.baseURL`，两者等价——显式传入可以让「反代前缀」
    ///     与客户端配置脱钩，便于将来接入多地址回退。
    public init(
        client: EmbyClient,
        userId: String,
        apiKey: String? = nil,
        baseURL: URL? = nil
    ) {
        self.client = client
        self.userId = userId
        self.apiKey = apiKey
        self.baseURL = baseURL ?? client.baseURL
    }

    /// 按关键词搜索。
    ///
    /// - Parameters:
    ///   - term: 关键词（首尾空白会被去掉）。
    ///   - limit: 最大条数。
    /// - Returns: 原始结果；人物已从条目里拆出来。
    /// - Throws: ``PrismCore/EmbyError``（取消时为 ``PrismCore/EmbyError/cancelled``）。
    public func search(_ term: String, limit: Int) async throws -> SearchResponse {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SearchResponse() }

        var query = ItemsQuery.search(trimmed)
        query.includeItemTypes = [.movie, .series, .episode, .person]
        query.limit = max(limit, 1)
        query.enableImages = true
        query.enableUserData = true
        query.imageTypeLimit = 1
        query.enableImageTypes = [.primary]

        let page = try await client.items(userId: userId, query: query)

        var items: [MediaItem] = []
        var people: [Person] = []
        items.reserveCapacity(page.items.count)

        for item in page.items {
            if item.type == .person {
                people.append(
                    Person(
                        id: item.id,
                        name: item.name,
                        role: nil,
                        type: item.type.rawValue,
                        primaryImageTag: item.primaryImageTag
                    )
                )
            } else {
                items.append(item)
            }
        }

        // 带上服务端总命中数：单页最多 `limit` 条，不能拿本页条数当结果总数。
        return SearchResponse(items: items, people: people, totalCount: page.totalRecordCount)
    }

    /// 解析条目 / 人物的图片地址。
    ///
    /// - Parameters:
    ///   - id: 条目 / 人物 id。
    ///   - tag: 图片 tag；`nil` 或空串表示没有该图片，直接返回 `nil`（避免 404）。
    ///   - maxWidth: 期望最大宽度；`<= 0` 时不传。
    /// - Returns: 图片地址；参数不完整时为 `nil`。
    public func imageURL(for id: String, tag: String?, maxWidth: Int) -> URL? {
        guard !id.isEmpty, let tag, !tag.isEmpty else { return nil }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        guard let escapedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }

        var basePath = components.path
        while basePath.hasSuffix("/") {
            basePath.removeLast()
        }
        components.path = basePath + "/Items/\(escapedId)/Images/Primary"

        var queryItems = [URLQueryItem(name: "tag", value: tag)]
        if maxWidth > 0 {
            queryItems.append(URLQueryItem(name: "maxWidth", value: String(maxWidth)))
        }
        if let apiKey, !apiKey.isEmpty {
            queryItems.append(URLQueryItem(name: "api_key", value: apiKey))
        }
        components.queryItems = queryItems

        return components.url
    }
}
