import AppKit
import Foundation
import PrismCore
import EmbyAPI

// MARK: - 演示模式数据源

/// 把 ``DemoEmbyClient`` 包成四个页面模块各自需要的 `*DataSource`。
///
/// **为什么需要它**：用户暂时没有可用的 Emby 服务器，但界面必须能完整演示。
/// 演示模式让 App 在没有服务器的情况下展示：
/// 首页（继续观看 / 接下来 / 最新 / 媒体库）、库网格、详情页、搜索、播放。
///
/// 与真实实现的关系：`Emby*DataSource` 包装 `EmbyClient`，这里包装 `DemoEmbyClient`。
/// 两者实现同一批协议，所以**页面代码一行都不用改**。
public enum DemoDataSources {

    // MARK: 会话

    /// 演示用的服务器连接。
    public static let server = ServerConnection(
        id: "demo-server",
        name: "演示服务器",
        baseURL: URL(string: "http://demo.local:8096") ?? URL(filePath: "/"),
        isDemo: true
    )

    /// 演示用户 id。
    public static let userId = "demo-user"

    /// 演示会话（登录成功后返回给外壳）。
    public static func makeSession() async throws -> AuthSession {
        let client = DemoEmbyClient.shared
        return try await client.authenticate(username: "演示用户", password: "")
    }

    // MARK: 首页

    /// 首页数据源。
    public struct Home: HomeDataSource {
        public init() {}

        public func resume() async throws -> [MediaItem] {
            try await DemoEmbyClient.shared.resume(userId: DemoDataSources.userId)
        }

        public func latest(limit: Int) async throws -> [MediaItem] {
            try await DemoEmbyClient.shared.latest(userId: DemoDataSources.userId, limit: limit)
        }

        public func nextUp() async throws -> [MediaItem] {
            try await DemoEmbyClient.shared.nextUp(userId: DemoDataSources.userId)
        }

        public func views() async throws -> [MediaView] {
            try await DemoEmbyClient.shared.views(userId: DemoDataSources.userId)
        }
    }

    // MARK: 媒体库

    /// 媒体库数据源。
    public struct Library: LibraryDataSource {
        public init() {}

        public func items(query: ItemsQuery) async throws -> ItemsQueryResult {
            try await DemoEmbyClient.shared.items(userId: DemoDataSources.userId, query: query)
        }

        public func markPlayed(itemId: String, played: Bool) async throws -> UserItemData {
            // 演示模式不真的改数据，返回一个「已标记」的结果让 UI 乐观更新后不回滚。
            UserItemData(
                playbackPosition: .zero,
                playCount: played ? 1 : 0,
                isFavorite: false,
                played: played,
                lastPlayedDate: nil,
                unplayedItemCount: nil
            )
        }

        public func markFavorite(itemId: String, favorite: Bool) async throws -> UserItemData {
            UserItemData(
                playbackPosition: .zero,
                playCount: 0,
                isFavorite: favorite,
                played: false,
                lastPlayedDate: nil,
                unplayedItemCount: nil
            )
        }

        public func imageURL(for item: MediaItem, kind: ImageKind, maxWidth: Int) -> URL? {
            // 演示模式的图由代码生成，不走网络。
            nil
        }
    }

    // MARK: 详情

    /// 详情数据源。
    public struct Detail: DetailDataSource {
        public init() {}

        public func itemDetail(itemId: String) async throws -> MediaItem {
            try await DemoEmbyClient.shared.itemDetail(userId: DemoDataSources.userId, itemId: itemId)
        }

        public func seasons(seriesId: String) async throws -> [MediaItem] {
            try await DemoEmbyClient.shared.seasons(seriesId: seriesId)
        }

        public func episodes(seriesId: String, seasonId: String?) async throws -> [MediaItem] {
            try await DemoEmbyClient.shared.episodes(
                seriesId: seriesId,
                userId: DemoDataSources.userId,
                seasonId: seasonId
            )
        }

        public func similar(itemId: String) async throws -> [MediaItem] {
            try await DemoEmbyClient.shared.similar(
                userId: DemoDataSources.userId,
                itemId: itemId
            )
        }

        public func setPlayed(itemId: String, played: Bool) async throws -> UserItemData {
            UserItemData(playbackPosition: .zero, playCount: played ? 1 : 0, isFavorite: false, played: played, lastPlayedDate: nil, unplayedItemCount: nil)
        }

        public func setFavorite(itemId: String, isFavorite: Bool) async throws -> UserItemData {
            UserItemData(playbackPosition: .zero, playCount: 0, isFavorite: isFavorite, played: false, lastPlayedDate: nil, unplayedItemCount: nil)
        }

        public func imageURL(itemId: String, kind: ImageKind, tag: String?, maxWidth: Int) -> URL? {
            // 演示模式的图由 `DemoArtwork` 代码生成，不走网络，所以这里返回 nil，
            // UI 会显示占位图（占位图本身也是渐变色块，视觉上足够）。
            nil
        }
    }

    // MARK: 搜索

    /// 搜索数据源。
    public struct Search: SearchDataSource {
        public init() {}

        public func search(_ term: String, limit: Int) async throws -> SearchResponse {
            var query = ItemsQuery()
            query.searchTerm = term
            query.limit = limit
            let result = try await DemoEmbyClient.shared.items(
                userId: DemoDataSources.userId,
                query: query
            )
            let items = result.items
            return SearchResponse(items: items, people: [])
        }
    }
}
