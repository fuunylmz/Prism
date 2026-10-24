import Foundation
import PrismCore
import SwiftUI

// MARK: - 预览数据

/// `#Preview` 与演示模式用的假搜索结果。
///
/// 全部指向 `preview.prism.invalid` 假域名，**不会发起真实请求**
/// （配合 ``PreviewImageLoader`` 更是完全不联网）；id 与文案都是虚构的，
/// 不含任何真实服务器信息。
enum SearchPreviewData {
    /// 假服务器 id。
    static let serverId = "preview-server"

    /// 假海报地址（复用设计系统的 ``PreviewData/posterURL(for:)``，保证同一 id 同图）。
    ///
    /// - Parameter id: 条目 id。
    /// - Returns: 假地址。
    static func posterURL(for id: String) -> URL? {
        PreviewData.posterURL(for: id)
    }

    // MARK: 电影

    /// 电影结果。
    static let movies: [MediaItem] = [
        MediaItem(
            id: "search-movie-1",
            name: "银翼杀手 2049",
            type: .movie,
            serverId: serverId,
            productionYear: 2017,
            runTime: Ticks(seconds: 9780),
            overview: "一名新一代银翼杀手揭开了尘封三十年的秘密。",
            officialRating: "R",
            communityRating: 8.0,
            genres: ["科幻", "剧情"],
            imageTags: [.primary: "search-tag-movie-1"],
            userData: UserItemData(
                playbackPosition: Ticks(seconds: 2100),
                playCount: 1,
                isFavorite: false,
                played: false,
                lastPlayedDate: nil,
                unplayedItemCount: nil
            )
        ),
        MediaItem(
            id: "search-movie-2",
            name: "降临",
            type: .movie,
            serverId: serverId,
            productionYear: 2016,
            runTime: Ticks(seconds: 6960),
            overview: "语言学家受雇于军方，试图与外星来客沟通。",
            officialRating: "PG-13",
            communityRating: 7.9,
            genres: ["科幻", "悬疑"],
            imageTags: [.primary: "search-tag-movie-2"],
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
            id: "search-movie-3",
            name: "沙丘",
            type: .movie,
            serverId: serverId,
            productionYear: 2021,
            runTime: Ticks(seconds: 9300),
            genres: ["科幻"],
            imageTags: [:],
            userData: .empty
        )
    ]

    // MARK: 剧集

    /// 剧集结果。
    static let series: [MediaItem] = [
        MediaItem(
            id: "search-series-1",
            name: "人生切割术",
            type: .series,
            serverId: serverId,
            productionYear: 2022,
            runTime: Ticks(seconds: 3300),
            overview: "一家公司用手术把员工的工作记忆与生活记忆分离。",
            officialRating: "TV-MA",
            communityRating: 8.7,
            genres: ["剧情", "科幻"],
            imageTags: [.primary: "search-tag-series-1"],
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
            id: "search-series-2",
            name: "Severance",
            type: .series,
            serverId: serverId,
            productionYear: 2022,
            imageTags: [.primary: "search-tag-series-2"],
            userData: .empty
        )
    ]

    // MARK: 单集

    /// 单集结果。
    static let episodes: [MediaItem] = [
        MediaItem(
            id: "search-episode-1",
            name: "第一集 · 早安，地狱",
            type: .episode,
            serverId: serverId,
            productionYear: 2022,
            runTime: Ticks(seconds: 3420),
            officialRating: "TV-MA",
            imageTags: [.primary: "search-tag-episode-1"],
            userData: UserItemData(
                playbackPosition: Ticks(seconds: 640),
                playCount: 0,
                isFavorite: false,
                played: false,
                lastPlayedDate: nil,
                unplayedItemCount: nil
            ),
            indexNumber: 1,
            parentIndexNumber: 1,
            seriesName: "人生切割术"
        ),
        MediaItem(
            id: "search-episode-2",
            name: "第二集 · 半个循环",
            type: .episode,
            serverId: serverId,
            productionYear: 2022,
            imageTags: [:],
            userData: .empty,
            indexNumber: 2,
            parentIndexNumber: 1,
            seriesName: "人生切割术"
        )
    ]

    /// 单集结果的第一条（预览用）。
    static let episode = episodes[0]

    // MARK: 人物

    /// 人物结果。
    static let people: [Person] = [
        Person(
            id: "search-person-1",
            name: "亚当·斯科特",
            role: "马克",
            type: "Actor",
            primaryImageTag: "search-tag-person-1"
        ),
        Person(
            id: "search-person-2",
            name: "布丽特·洛薇尔",
            role: "海莉",
            type: "Actor",
            primaryImageTag: "search-tag-person-2"
        ),
        Person(
            id: "search-person-3",
            name: "本·斯蒂勒",
            type: "Director",
            primaryImageTag: nil
        )
    ]

    // MARK: 组合

    /// 有结果的状态值。
    static let results = SearchResults(
        movies: movies,
        series: series,
        episodes: episodes,
        people: people
    )

    /// 空结果。
    static let emptyResults = SearchResults()

    /// 可恢复错误（用于错误态预览）。
    static let recoverableError: EmbyError = .serverUnreachable("预览数据：连接被拒绝")
}

// MARK: - 预览图片地址

/// 预览用的图片地址提供者：返回假域名，配合 ``PreviewImageLoader`` 生成渐变图。
struct SearchPreviewImageProvider: SearchImageProviding {
    /// 解析假图片地址。
    ///
    /// - Parameters:
    ///   - id: 条目 / 人物 id。
    ///   - tag: 图片 tag；`nil` 时返回 `nil`（演示「没有图片」的占位图）。
    ///   - maxWidth: 期望宽度（忽略）。
    /// - Returns: 假地址。
    func imageURL(for id: String, kind: ImageKind, tag: String?, maxWidth: Int) -> URL? {
        guard tag?.isEmpty == false else { return nil }
        return SearchPreviewData.posterURL(for: id)
    }
}

// MARK: - 预览数据源

/// 预览 / 演示模式用的数据源：返回固定结果，可选延迟与错误。
///
/// 与 ``InertSearchDataSource`` 的区别：它真的有结果，因此可以在预览里点开
/// 「最近搜索 → 搜索结果」的完整链路。
struct SearchPreviewDataSource: SearchDataSource, SearchImageProviding {
    /// 人为延迟，用于观察骨架屏。
    let delay: Duration

    /// 非 `nil` 时抛该错误，用于观察错误态。
    let failure: EmbyError?

    /// 创建数据源。
    ///
    /// - Parameters:
    ///   - delay: 人为延迟，默认 0。
    ///   - failure: 要抛出的错误，默认 `nil`（成功）。
    init(delay: Duration = .zero, failure: EmbyError? = nil) {
        self.delay = delay
        self.failure = failure
    }

    func search(_ term: String, limit: Int) async throws -> SearchResponse {
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        if let failure {
            throw failure
        }
        guard !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return SearchResponse()
        }
        return SearchResponse(
            items: SearchPreviewData.movies + SearchPreviewData.series + SearchPreviewData.episodes,
            people: SearchPreviewData.people
        )
    }

    func imageURL(for id: String, kind: ImageKind, tag: String?, maxWidth: Int) -> URL? {
        guard tag?.isEmpty == false else { return nil }
        return SearchPreviewData.posterURL(for: id)
    }
}

// MARK: - 预览

/// 预览宿主：用真实的 `SearchViewModel` 跑一次搜索，观察「加载 → 结果」的完整链路。
private struct SearchFlowPreviewHost: View {
    @State private var viewModel = SearchViewModel(
        dataSource: SearchPreviewDataSource(delay: .milliseconds(600)),
        imageProvider: SearchPreviewImageProvider()
    )

    var body: some View {
        SearchView(viewModel: viewModel)
            .prismTheme(PrismTheme(appearance: .dark))
            .environment(\.posterImageLoader, PreviewImageLoader())
            .frame(width: 860, height: 720)
            .task {
                viewModel.query = "切"
            }
    }
}

#Preview("搜索 · 真实防抖链路") {
    SearchFlowPreviewHost()
}
