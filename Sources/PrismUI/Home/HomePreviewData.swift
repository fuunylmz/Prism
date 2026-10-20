import EmbyAPI
import Foundation
import PrismCore
import SwiftUI

// MARK: - 预览数据源

/// `#Preview` 用的假数据源。
///
/// 它实现的是**真实的** ``HomeDataSource`` 协议，因此预览走的是与线上完全相同的
/// 视图模型代码路径（并发、部分成功、空态、错误态都是真的跑一遍），
/// 而不是在预览里手工塞一个 `LoadState`。
struct PreviewHomeDataSource: HomeDataSource {
    /// 数据源行为。
    enum Mode: Sendable {
        /// 四个分区都有数据。
        case loaded
        /// 四个分区都成功但都是空的（新服务器 / 空库）。
        case empty
        /// 四个分区全部失败（整页错误）。
        case failing
        /// 永远不返回：用来观察加载骨架。
        case loading
        /// 「接下来」「媒体库」失败，其余成功（部分成功 + 内联错误条）。
        case partialFailure
    }

    let mode: Mode

    init(mode: Mode = .loaded) {
        self.mode = mode
    }

    func resume() async throws -> [MediaItem] {
        try await respond(HomePreviewData.resumeItems)
    }

    func latest(limit: Int) async throws -> [MediaItem] {
        try await respond(HomePreviewData.latestItems)
    }

    func nextUp() async throws -> [MediaItem] {
        try await respond(HomePreviewData.nextUpItems)
    }

    func views() async throws -> [MediaView] {
        try await respondLibraries(HomePreviewData.libraryViews)
    }

    /// 按 ``mode`` 决定「返回数据 / 返回空 / 抛错 / 挂起」。
    ///
    /// - Parameter items: 该分区在 `.loaded` 下的数据。
    /// - Returns: 分区条目。
    private func respond(_ items: [MediaItem]) async throws -> [MediaItem] {
        switch mode {
        case .loaded:
            return items
        case .empty:
            return []
        case .failing:
            throw EmbyError.serverUnreachable("预览数据：连接被拒绝")
        case .partialFailure:
            return items
        case .loading:
            try await Task.sleep(for: .seconds(3600))
            return []
        }
    }

    /// 媒体库分区的同款行为（返回 `MediaView`）。
    ///
    /// - Parameter libraries: `.loaded` 下的媒体库列表。
    /// - Returns: 媒体库列表。
    private func respondLibraries(_ libraries: [MediaView]) async throws -> [MediaView] {
        switch mode {
        case .loaded, .partialFailure:
            return libraries
        case .empty:
            return []
        case .failing:
            throw EmbyError.serverUnreachable("预览数据：连接被拒绝")
        case .loading:
            try await Task.sleep(for: .seconds(3600))
            return []
        }
    }
}

// MARK: - 假数据

/// 首页预览用的假条目。
///
/// 所有条目都指向 `preview.prism.invalid` 假域名，配合 `PreviewImageLoader`
/// **完全不联网**。
enum HomePreviewData {
    /// 预览服务器地址（假域名，不会真的发请求）。
    static let baseURL = URL(string: "https://preview.prism.invalid") ?? URL(fileURLWithPath: "/")

    /// 预览用图片解析器（无令牌）。
    static let imageResolver = HomeImageResolver(baseURL: baseURL)

    // MARK: 继续观看

    /// 看到一半的电影（剩余约 2 小时 8 分）。
    static let inProgressMovie = MediaItem(
        id: "home-movie-1",
        name: "银翼杀手 2049",
        type: .movie,
        serverId: "preview-server",
        productionYear: 2017,
        runTime: Ticks(seconds: 9780),
        overview: "一名新一代银翼杀手揭开了尘封三十年的秘密。",
        officialRating: "R",
        communityRating: 8.0,
        genres: ["科幻", "剧情"],
        imageTags: [.primary: "tag-movie-1"],
        backdropTags: ["bd-movie-1"],
        userData: UserItemData(
            playbackPosition: Ticks(seconds: 2100),
            playCount: 1,
            isFavorite: false,
            played: false,
            lastPlayedDate: nil,
            unplayedItemCount: nil
        )
    )

    /// 看到一半的单集（剩余 32 分钟）。
    static let inProgressEpisode = MediaItem(
        id: "home-episode-1",
        name: "第一集 · 好消息",
        type: .episode,
        serverId: "preview-server",
        productionYear: 2022,
        runTime: Ticks(seconds: 3420),
        overview: "新员工入职的第一天。",
        officialRating: "TV-MA",
        communityRating: 8.4,
        genres: ["剧情"],
        imageTags: [.primary: "tag-episode-1"],
        backdropTags: ["bd-episode-1"],
        userData: UserItemData(
            playbackPosition: Ticks(seconds: 1500),
            playCount: 0,
            isFavorite: false,
            played: false,
            lastPlayedDate: nil,
            unplayedItemCount: nil
        ),
        seriesId: "home-series-1",
        indexNumber: 1,
        parentIndexNumber: 1,
        seriesName: "人生切割术"
    )

    /// 没有进度的单集（验证「剩余时间」缺失时的表现）。
    static let noProgressEpisode = MediaItem(
        id: "home-episode-2",
        name: "第二集 · 半循环",
        type: .episode,
        serverId: "preview-server",
        productionYear: 2022,
        runTime: Ticks(seconds: 3300),
        imageTags: [.primary: "tag-episode-2"],
        backdropTags: ["bd-episode-2"],
        userData: UserItemData(
            playbackPosition: Ticks(seconds: 120),
            playCount: 0,
            isFavorite: false,
            played: false,
            lastPlayedDate: nil,
            unplayedItemCount: nil
        ),
        seriesId: "home-series-1",
        indexNumber: 2,
        parentIndexNumber: 1,
        seriesName: "人生切割术"
    )

    /// 没有任何图片的条目（验证占位图）。
    static let missingArtwork = MediaItem(
        id: "home-movie-no-art",
        name: "没有海报的电影",
        type: .movie,
        serverId: "preview-server",
        productionYear: 2001,
        runTime: Ticks(seconds: 5400),
        userData: UserItemData(
            playbackPosition: Ticks(seconds: 600),
            playCount: 0,
            isFavorite: false,
            played: false,
            lastPlayedDate: nil,
            unplayedItemCount: nil
        )
    )

    /// 时长未知的条目（验证「剩余时间」整行不显示）。
    static let unknownRuntime = MediaItem(
        id: "home-movie-unknown-runtime",
        name: "时长未知",
        type: .movie,
        serverId: "preview-server",
        imageTags: [.primary: "tag-unknown-runtime"],
        backdropTags: ["bd-unknown-runtime"],
        userData: UserItemData(
            playbackPosition: Ticks(seconds: 60),
            playCount: 0,
            isFavorite: false,
            played: false,
            lastPlayedDate: nil,
            unplayedItemCount: nil
        )
    )

    /// 继续观看分区。
    static let resumeItems: [MediaItem] = [inProgressMovie, inProgressEpisode, noProgressEpisode]

    // MARK: 接下来

    /// 「接下来」分区：剧集的下一集。
    static let nextUpItems: [MediaItem] = (1...5).map { index in
        MediaItem(
            id: "home-next-\(index)",
            name: "第 \(index) 集",
            type: .episode,
            serverId: "preview-server",
            productionYear: 2022,
            runTime: Ticks(seconds: 3300),
            imageTags: [.primary: "tag-next-\(index)"],
            userData: UserItemData(
                playbackPosition: .zero,
                playCount: 0,
                isFavorite: false,
                played: false,
                lastPlayedDate: nil,
                unplayedItemCount: nil
            ),
            seriesId: "home-series-\(index % 2 + 1)",
            indexNumber: index,
            parentIndexNumber: index % 2 + 1,
            seriesName: index % 2 == 0 ? "怒呛人生" : "人生切割术"
        )
    }

    // MARK: 最新添加

    /// 「最新添加」分区。
    static let latestItems: [MediaItem] = [
        MediaItem(
            id: "home-latest-1",
            name: "沙丘 2",
            type: .movie,
            serverId: "preview-server",
            productionYear: 2024,
            runTime: Ticks(seconds: 9960),
            imageTags: [.primary: "tag-latest-1"],
            userData: .empty
        ),
        MediaItem(
            id: "home-latest-2",
            name: "人生切割术",
            type: .series,
            serverId: "preview-server",
            productionYear: 2022,
            imageTags: [.primary: "tag-latest-2"],
            userData: UserItemData(
                playbackPosition: .zero,
                playCount: 0,
                isFavorite: false,
                played: false,
                lastPlayedDate: nil,
                unplayedItemCount: 7
            )
        ),
        MediaItem(
            id: "home-latest-3",
            name: "降临",
            type: .movie,
            serverId: "preview-server",
            productionYear: 2016,
            imageTags: [.primary: "tag-latest-3"],
            userData: UserItemData(
                playbackPosition: .zero,
                playCount: 2,
                isFavorite: true,
                played: true,
                lastPlayedDate: nil,
                unplayedItemCount: nil
            )
        ),
        MediaItem(
            id: "home-latest-4",
            name: "怒呛人生",
            type: .series,
            serverId: "preview-server",
            productionYear: 2023,
            imageTags: [.primary: "tag-latest-4"],
            userData: .empty
        ),
        MediaItem(
            id: "home-latest-5",
            name: "奥本海默",
            type: .movie,
            serverId: "preview-server",
            productionYear: 2023,
            imageTags: [.primary: "tag-latest-5"],
            userData: .empty
        ),
        MediaItem(
            id: "home-latest-6",
            name: "没有海报的新片",
            type: .movie,
            serverId: "preview-server",
            productionYear: 2025,
            userData: .empty
        )
    ]

    // MARK: 媒体库

    /// 媒体库入口（保留服务端 `CollectionType`）。
    static let libraryViews: [MediaView] = [
        library(id: "lib-movies", name: "电影", collectionType: .movies, artwork: "tag-lib-movies", count: 412),
        library(id: "lib-tv", name: "剧集", collectionType: .tvShows, artwork: "tag-lib-tv", count: 38),
        library(id: "lib-anime", name: "动画", collectionType: .tvShows, artwork: "tag-lib-anime", count: 96),
        library(id: "lib-doc", name: "纪录片", collectionType: .movies, artwork: "tag-lib-doc", count: 24)
    ]

    /// 没有封面图的媒体库（验证网格里的占位图标）。
    static let offlineLibrary = library(
        id: "lib-offline",
        name: "未挂载的库",
        collectionType: nil,
        artwork: nil,
        count: nil
    )

    /// 构造一个媒体库入口。
    ///
    /// - Parameters:
    ///   - id: 库 id。
    ///   - name: 库名。
    ///   - collectionType: 服务端库类型；`nil` 表示混合库。
    ///   - artwork: 主图 tag；`nil` 表示没有封面。
    ///   - count: 条目数。
    /// - Returns: 媒体库入口。
    private static func library(
        id: String,
        name: String,
        collectionType: LibraryType?,
        artwork: String?,
        count: Int?
    ) -> MediaView {
        MediaView(
            item: MediaItem(
                id: id,
                name: name,
                type: .collectionFolder,
                serverId: "preview-server",
                imageTags: artwork.map { [ImageKind.primary: $0] } ?? [:],
                childCount: count,
                isFolder: true
            ),
            collectionType: collectionType
        )
    }
}
