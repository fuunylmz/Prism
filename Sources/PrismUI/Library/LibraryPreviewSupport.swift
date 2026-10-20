import EmbyAPI
import Foundation
import PrismCore

// MARK: - 预览数据

/// `#Preview` 与离线演示用的假数据。
///
/// 只在预览里使用，不参与生产路径。所有海报地址都指向 `preview.prism.invalid`
/// 假域名，配合 ``PrismUI/PreviewImageLoader`` 完全不联网
/// （见 `DesignSystem/PreviewSupport.swift`）。
enum LibraryPreviewData {
    /// 条目总数：够铺满两屏，能看清网格密度与无限滚动的底部占位。
    static let itemCount = 24

    /// 标题池（循环取用，避免 24 个「示例影片」）。
    private static let titles = [
        "银翼杀手 2049", "降临", "人生切割术", "沙丘", "星际穿越",
        "海边的曼彻斯特", "寄生虫", "燃烧", "小丑", "灯塔",
        "疯狂的麦克斯：狂暴之路", "异形", "2001 太空漫游", "她", "月光男孩",
        "犬之岛", "蜘蛛侠：平行宇宙", "降临之二", "消失的爱人", "真探",
        "西部世界", "切尔诺贝利", "王冠", "黑镜"
    ]

    /// 简介池。
    private static let overviews = [
        "一名新一代银翼杀手揭开了尘封三十年的秘密，这个秘密有可能让社会陷入混乱。",
        "语言学家受雇于军方，试图与外星来客沟通，最终改变了自己对时间的理解。",
        "一家公司用手术把员工的工作记忆与生活记忆彻底分离。",
        "在沙漠星球上，一个少年必须面对家族、预言与帝国的三重阴影。",
        "一支探险队穿越虫洞，为人类寻找新的家园。",
        "一个男人回到故乡处理哥哥的后事，被迫面对自己逃避多年的过去。"
    ]

    /// 类型池（真实 Emby 里是英文或中文标签，取决于服务端元数据语言）。
    static let genres = ["剧情", "科幻", "悬疑", "犯罪", "动画", "纪录片"]

    /// 生成第 `index` 条假数据。
    ///
    /// - Parameter index: 序号（0 基）。
    /// - Returns: 假条目。
    static func item(index: Int) -> MediaItem {
        let isSeries = index % 5 == 0
        let isWatched = index % 3 == 0
        let isInProgress = index % 4 == 1 && !isWatched
        let year = 1996 + (index % 28)
        let runtime = Ticks(seconds: Double(5_400 + (index % 7) * 600))
        let position = isInProgress ? Ticks(seconds: Double(600 + index * 30)) : .zero

        return MediaItem(
            id: "preview-item-\(index)",
            name: titles[index % titles.count],
            type: isSeries ? .series : .movie,
            serverId: "preview-server",
            productionYear: year,
            runTime: runtime,
            overview: overviews[index % overviews.count],
            officialRating: isSeries ? "TV-MA" : "PG-13",
            communityRating: 6.0 + Double(index % 35) / 10,
            genres: [genres[index % genres.count], genres[(index + 2) % genres.count]],
            imageTags: [.primary: "preview-tag-\(index)"],
            userData: UserItemData(
                playbackPosition: position,
                playCount: isWatched ? 2 : 0,
                isFavorite: index % 7 == 0,
                played: isWatched,
                lastPlayedDate: nil,
                unplayedItemCount: isSeries ? (index % 8) + 1 : nil
            )
        )
    }

    /// 一组假条目。
    static let items: [MediaItem] = (0..<itemCount).map(item(index:))

    /// 假海报地址（只给 ``PrismUI/PreviewImageLoader`` 用）。
    ///
    /// - Parameter id: 条目 id。
    /// - Returns: 假地址；字符串恒定合法。
    static func posterURL(for id: String) -> URL? {
        URL(string: "https://preview.prism.invalid/posters/\(id).jpg")
    }
}

// MARK: - 预览数据源

/// 离线数据源：按 ``Outcome`` 返回假数据，用来在预览里演示四态。
struct LibraryPreviewDataSource: LibraryDataSource {
    /// 预览要演示的结果。
    enum Outcome: Sendable {
        /// 有数据（按 `query` 分页）。
        case items([MediaItem])
        /// 空库。
        case empty
        /// 请求失败。
        case failure(EmbyError)
        /// 永不返回：让骨架屏一直显示。
        case pending
    }

    /// 结果。
    let outcome: Outcome

    /// 创建数据源。
    ///
    /// - Parameter outcome: 要演示的结果，默认 24 条假数据。
    init(outcome: Outcome = .items(LibraryPreviewData.items)) {
        self.outcome = outcome
    }

    func items(query: ItemsQuery) async throws -> ItemsQueryResult {
        switch outcome {
        case .pending:
            // 睡到预览被销毁；取消时抛 `CancellationError`，由 VM 静默处理。
            try await Task.sleep(for: .seconds(3_600))
            return ItemsQueryResult(items: [], totalRecordCount: 0)
        case let .failure(error):
            throw error
        case .empty:
            return ItemsQueryResult(items: [], totalRecordCount: 0)
        case let .items(all):
            let start = min(max(query.startIndex ?? 0, 0), all.count)
            let limit = max(query.limit ?? all.count, 0)
            let end = min(start + limit, all.count)
            return ItemsQueryResult(
                items: Array(all[start..<end]),
                totalRecordCount: all.count,
                startIndex: start
            )
        }
    }

    func markPlayed(itemId: String, played: Bool) async throws -> UserItemData {
        UserItemData(
            playbackPosition: .zero,
            playCount: played ? 1 : 0,
            isFavorite: false,
            played: played,
            lastPlayedDate: nil,
            unplayedItemCount: nil
        )
    }

    func markFavorite(itemId: String, favorite: Bool) async throws -> UserItemData {
        UserItemData(
            playbackPosition: .zero,
            playCount: 0,
            isFavorite: favorite,
            played: false,
            lastPlayedDate: nil,
            unplayedItemCount: nil
        )
    }

    func imageURL(for item: MediaItem, kind: ImageKind, maxWidth: Int) -> URL? {
        LibraryPreviewData.posterURL(for: item.id)
    }
}

// MARK: - 预览工厂

/// 预览用的视图模型工厂。
@MainActor
enum LibraryPreview {
    /// 创建预览用的视图模型。
    ///
    /// - Parameters:
    ///   - outcome: 要演示的结果。
    ///   - layout: 布局，默认网格。
    ///   - sort: 排序，默认最近添加。
    ///   - filters: 筛选，默认无。
    /// - Returns: 已注入假数据源的视图模型。
    static func viewModel(
        outcome: LibraryPreviewDataSource.Outcome = .items(LibraryPreviewData.items),
        layout: GridLayout = .poster,
        sort: SortOption = .recentlyAdded,
        filters: FilterSet = .none
    ) -> LibraryViewModel {
        LibraryViewModel(
            dataSource: LibraryPreviewDataSource(outcome: outcome),
            libraryId: "preview-library",
            kind: .video,
            includeItemTypes: [.movie, .series],
            sort: sort,
            filters: filters,
            layout: layout
        )
    }
}
