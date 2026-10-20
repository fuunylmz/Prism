import EmbyAPI
import Foundation

// MARK: - 排序选项

/// 媒体库的排序方式。
///
/// 每个选项都直接映射到 Emby `/Users/{userId}/Items` 的 `SortBy` + `SortOrder`：
///
/// | 选项 | `SortBy` | `SortOrder` |
/// |---|---|---|
/// | 最近添加 | `DateCreated` | `Descending` |
/// | 标题 A-Z | `SortName` | `Ascending` |
/// | 年份 | `ProductionYear,SortName` | `Descending,Ascending` |
/// | 评分 | `CommunityRating,SortName` | `Descending,Ascending` |
/// | 时长 | `Runtime` | `Descending` |
///
/// ## 两个必须记住的坑（来自 `docs/research/emby-api.md`）
///
/// 1. **`SortBy` 是逗号分隔的多字段列表**，`SortOrder` 与它**按位置一一对应**
///    （<https://dev.emby.media/doc/restapi/Browsing-the-Library.html>）。
///    本类型因此暴露的是 `[ItemSortBy]` / `[SortOrder]` 数组，
///    由 ``EmbyAPI/ItemsQuery`` 统一拼成逗号列表，**调用方不要自己拼字符串**。
/// 2. 多字段排序的第二字段用 `SortName` 兜底，否则同一年份 / 同一评分的条目
///    在不同分页里可能顺序漂移，导致无限滚动出现重复或漏项。
///
/// ## 深链
///
/// ``rawValue`` 同时是 URL 参数值（`sort=recent`），v1.1 深链与偏好持久化都用它。
public enum SortOption: String, Sendable, Hashable, CaseIterable, Codable, Identifiable {
    /// 最近添加（入库时间倒序）。
    case recentlyAdded = "recent"
    /// 标题 A-Z（按 `SortName`，忽略 `The ` 之类前缀）。
    case titleAscending = "title"
    /// 年份（新 → 旧）。
    case year = "year"
    /// 社区评分（高 → 低）。
    case rating = "rating"
    /// 时长（长 → 短）。
    case runtime = "runtime"

    /// `Identifiable` 要求的稳定 id。
    public var id: String { rawValue }

    /// 菜单上的中文标题。
    public var title: String {
        switch self {
        case .recentlyAdded: "最近添加"
        case .titleAscending: "标题 A-Z"
        case .year: "年份"
        case .rating: "评分"
        case .runtime: "时长"
        }
    }

    /// 菜单上的 SF Symbol 名称。
    public var systemImage: String {
        switch self {
        case .recentlyAdded: "clock"
        case .titleAscending: "textformat.abc"
        case .year: "calendar"
        case .rating: "star"
        case .runtime: "timer"
        }
    }

    // MARK: - Emby 查询映射

    /// 传给 `SortBy` 的字段列表（**逗号分隔由查询构建器负责**）。
    public var sortBy: [ItemSortBy] {
        // 每个排序都必须以 `SortName` 收尾。
        //
        // 只按 `DateCreated` / `Runtime` 排，同一批导入的条目会大量并列；
        // Emby 对并列项不保证稳定次序，翻页时同一部片子可能出现在两页里、
        // 也可能一页都刷不到（我们按 id 去重，重复项会被静默吞掉）。
        switch self {
        case .recentlyAdded:
            [.dateCreated, .sortName]
        case .titleAscending:
            [.sortName]
        case .year:
            [.productionYear, .sortName]
        case .rating:
            [.communityRating, .sortName]
        case .runtime:
            [.runtime, .sortName]
        }
    }

    /// 传给 `SortOrder` 的方向列表，与 ``sortBy`` **等长且按位置对应**。
    ///
    /// - Important: 返回类型写 ``EmbySortOrder`` 而不是裸 `SortOrder`：
    ///   macOS 26 SDK 的 Foundation 也有一个 `SortOrder`（`SortDescriptor` 用的），
    ///   本文件同时 `import Foundation` 与 `import EmbyAPI`，裸写会报
    ///   「`'SortOrder' is ambiguous for type lookup in this context`」。
    ///   别名定义见 `EmbySortOrderAlias.swift`。
    public var sortOrders: [EmbySortOrder] {
        switch self {
        case .recentlyAdded:
            [.descending, .ascending]
        case .titleAscending:
            [.ascending]
        case .year, .rating:
            [.descending, .ascending]
        case .runtime:
            [.descending, .ascending]
        }
    }

    /// `SortBy` 的最终参数值（逗号分隔）。
    ///
    /// 只给「需要裸字符串」的调用方（例如 v1.1 深链、日志）使用；
    /// 正常路径请把 ``sortBy`` / ``sortOrders`` 直接赋给 ``EmbyAPI/ItemsQuery``。
    public var sortByParameter: String {
        sortBy.map(\.rawValue).joined(separator: ",")
    }

    /// `SortOrder` 的最终参数值（逗号分隔）。
    public var sortOrderParameter: String {
        sortOrders.map(\.rawValue).joined(separator: ",")
    }

    // MARK: - 深链

    /// 写进 URL 的查询项（`sort=recent`）。
    public var queryItems: [URLQueryItem] {
        [URLQueryItem(name: "sort", value: rawValue)]
    }

    /// 从深链查询项里读回排序方式。
    ///
    /// - Parameter queryItems: 解析后的查询项。
    /// - Returns: 识别出的排序方式；缺失或无法识别时为 `nil`（调用方回落到默认值）。
    public init?(queryItems: [URLQueryItem]) {
        guard let value = queryItems.first(where: { $0.name == "sort" })?.value,
              let option = SortOption(rawValue: value)
        else { return nil }
        self = option
    }
}
