import EmbyAPI
import Foundation

// MARK: - 筛选集合

/// 媒体库的筛选条件集合。
///
/// 覆盖 `docs/research/ux-benchmark.md` §S06「筛选与排序栏」中 v1.0 承诺的四组：
/// 观看状态、类型（`Genres`）、年份范围、评分下限。
///
/// ## 参数映射（两个「分隔符」坑）
///
/// | 条件 | Emby 参数 | 分隔符 |
/// |---|---|---|
/// | 观看状态 | `IsPlayed` | 布尔，无分隔符 |
/// | 类型 | `Genres` | **竖线 `\|`** |
/// | 年份范围 | `Years` | 逗号 `,` |
/// | 评分下限 | `MinCommunityRating` | 数值 |
///
/// `Genres` / `Tags` / `Studios` / `OfficialRatings` 是**竖线分隔**，而
/// `Years` / `SortBy` / `IncludeItemTypes` 是**逗号分隔**（见
/// `Sources/EmbyAPI/Endpoints/ItemsQuery.swift` 顶部注释与 `docs/research/emby-api.md`）。
/// 本类型只产出数组，分隔符由 ``EmbyAPI/ItemsQuery`` 负责，避免两处拼错。
///
/// ## 深链
///
/// ``queryItems`` / ``init(queryItems:)`` 与 ``deepLinkQuery`` 提供 URL 级序列化，
/// 供 v1.1 深链与「返回时恢复筛选」使用。key 为 `played` / `genre` / `year` / `rating`，
/// 其中 `genre` 可重复出现。
public struct FilterSet: Sendable, Hashable, Codable {
    // MARK: 观看状态

    /// 观看状态（单选）。
    public enum WatchState: String, Sendable, Hashable, CaseIterable, Codable, Identifiable {
        /// 全部（不筛选）。
        case all
        /// 未看。
        case unwatched
        /// 已看。
        case watched

        /// `Identifiable` 要求的稳定 id。
        public var id: String { rawValue }

        /// 分段控件 / 菜单上的文案。
        public var title: String {
            switch self {
            case .all: "全部"
            case .unwatched: "未看"
            case .watched: "已看"
            }
        }

        /// 是否为「正在生效」的筛选（`all` 表示不筛）。
        public var isActive: Bool {
            self != .all
        }

        /// 映射到 `IsPlayed` 参数；`all` 返回 `nil`（不发送该参数）。
        public var isPlayed: Bool? {
            switch self {
            case .all: nil
            case .unwatched: false
            case .watched: true
            }
        }
    }

    // MARK: 属性

    /// 观看状态，默认全部。
    public var watchState: WatchState

    /// 选中的类型（`Genres`，多选）。
    ///
    /// 用 `Set` 而不是 `Array`：勾选是集合语义，天然去重且与 UI 的开关一一对应。
    /// 需要稳定顺序时用 ``sortedGenres``。
    public var genres: Set<String>

    /// 年份范围（闭区间，含两端）；`nil` 表示不限。
    public var yearRange: ClosedRange<Int>?

    /// 社区评分下限（0...10）；`nil` 表示不限。
    public var minimumRating: Double?

    // MARK: 初始化

    /// 创建一个筛选集合。
    ///
    /// - Parameters:
    ///   - watchState: 观看状态，默认 ``WatchState/all``。
    ///   - genres: 类型集合，默认空。
    ///   - yearRange: 年份范围，默认不限。
    ///   - minimumRating: 评分下限，默认不限。
    public init(
        watchState: WatchState = .all,
        genres: Set<String> = [],
        yearRange: ClosedRange<Int>? = nil,
        minimumRating: Double? = nil
    ) {
        self.watchState = watchState
        self.genres = genres
        self.yearRange = yearRange
        self.minimumRating = minimumRating
    }

    /// 空筛选（等价于 `FilterSet()`）。
    public static let none = FilterSet()

    // MARK: 派生状态

    /// 是否没有任何筛选条件。
    public var isEmpty: Bool {
        activeFilterCount == 0
    }

    /// 是否至少有一个筛选条件（`!isEmpty` 的可读写法）。
    public var isFiltered: Bool {
        !isEmpty
    }

    /// 生效中的条件个数，用于筛选按钮的徽标数字。
    ///
    /// 每个类型算一条：勾了 3 个类型就是 3。
    public var activeFilterCount: Int {
        var count = 0
        if watchState.isActive { count += 1 }
        count += genres.count
        if yearRange != nil { count += 1 }
        if minimumRating != nil { count += 1 }
        return count
    }

    /// 按字母序排好的类型列表（用于 chip、菜单与快照对比）。
    public var sortedGenres: [String] {
        genres.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: 不可变更新

    /// 返回替换了观看状态的新集合。
    ///
    /// - Parameter watchState: 新的观看状态。
    /// - Returns: 新集合；原集合不变。
    public func setting(watchState: WatchState) -> FilterSet {
        var copy = self
        copy.watchState = watchState
        return copy
    }

    /// 返回切换了某个类型（勾上 / 取消）的新集合。
    ///
    /// - Parameter genre: 类型名（服务端 `Genres` 里的原字符串）。
    /// - Returns: 新集合；原集合不变。
    public func togglingGenre(_ genre: String) -> FilterSet {
        var copy = self
        if copy.genres.contains(genre) {
            copy.genres.remove(genre)
        } else {
            copy.genres.insert(genre)
        }
        return copy
    }

    /// 返回替换了年份范围的新集合。
    ///
    /// - Parameter range: 年份闭区间；`nil` 表示不限。
    /// - Returns: 新集合；原集合不变。
    public func settingYearRange(_ range: ClosedRange<Int>?) -> FilterSet {
        var copy = self
        copy.yearRange = range
        return copy
    }

    /// 返回替换了评分下限的新集合。
    ///
    /// - Parameter rating: 0...10 的评分下限；`nil` 表示不限。超出范围会被夹到 0...10。
    /// - Returns: 新集合；原集合不变。
    public func settingMinimumRating(_ rating: Double?) -> FilterSet {
        var copy = self
        copy.minimumRating = rating.map { min(max($0, 0), 10) }
        return copy
    }

    /// 返回清空全部条件的新集合。
    public func cleared() -> FilterSet {
        FilterSet()
    }

    // MARK: - Emby 查询映射

    /// `IsPlayed` 参数值。
    public var isPlayed: Bool? {
        watchState.isPlayed
    }

    /// `Genres` 参数值（**竖线分隔由查询构建器负责**）。
    public var genreList: [String] {
        sortedGenres
    }

    /// `Years` 参数值。
    ///
    /// 年份范围展开成具体年份列表：Emby 的 `Years` 是「或」语义的年份集合，
    /// 没有「区间」参数（`MinPremiereDate` 是首播日期，不是出品年份，不能替代）。
    /// 区间最多展开 ``maximumExpandedYears`` 项，防止异常区间把 URL 撑爆。
    public var years: [Int] {
        guard let yearRange else { return [] }
        let clampedLower = max(yearRange.lowerBound, 0)
        let clampedUpper = min(yearRange.upperBound, 9999)
        guard clampedLower <= clampedUpper else { return [] }
        let count = clampedUpper - clampedLower + 1
        guard count <= Self.maximumExpandedYears else { return [] }
        return Array(clampedLower...clampedUpper)
    }

    /// `Years` 最多展开多少项（超过则视为无效筛选，不发送）。
    public static let maximumExpandedYears = 200

    /// `MinCommunityRating` 参数值。
    public var minCommunityRating: Double? {
        minimumRating
    }

    // MARK: - 深链

    /// 写进 URL 的查询项。
    ///
    /// 只输出生效中的条件，顺序稳定（先 `played`，再按字母序 `genre`，最后 `year` / `rating`），
    /// 便于测试与缓存。
    public var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if watchState.isActive {
            items.append(URLQueryItem(name: "played", value: watchState.rawValue))
        }
        for genre in sortedGenres {
            items.append(URLQueryItem(name: "genre", value: genre))
        }
        if let yearRange {
            items.append(
                URLQueryItem(
                    name: "year",
                    value: "\(yearRange.lowerBound)-\(yearRange.upperBound)"
                )
            )
        }
        if let minimumRating {
            items.append(URLQueryItem(name: "rating", value: Self.formatRating(minimumRating)))
        }
        return items
    }

    /// 从深链查询项里读回筛选条件。
    ///
    /// 无法识别的 key / 值会被**忽略**（而不是整体失败），
    /// 这样 v1.1 新增筛选维度时旧链接仍然可用。
    ///
    /// - Parameter queryItems: 解析后的查询项。
    public init(queryItems: [URLQueryItem]) {
        self.init()
        for item in queryItems {
            switch item.name {
            case "played":
                if let raw = item.value, let state = WatchState(rawValue: raw) {
                    watchState = state
                }
            case "genre":
                if let value = item.value, !value.isEmpty {
                    genres.insert(value)
                }
            case "year":
                if let range = Self.parseYearRange(item.value) {
                    yearRange = range
                }
            case "rating":
                if let raw = item.value, let value = Double(raw) {
                    minimumRating = min(max(value, 0), 10)
                }
            default:
                continue
            }
        }
    }

    /// 百分号编码后的查询串（不含前导 `?`），用于 v1.1 深链。
    ///
    /// 类型名可能含中文（`科幻`），因此必须走 `URLComponents` 编码，
    /// 不能手工拼接。
    public var deepLinkQuery: String {
        var components = URLComponents()
        components.queryItems = queryItems
        return components.percentEncodedQuery ?? ""
    }

    /// 评分格式化：整数不显示小数点（`8` 而不是 `8.0`）。
    ///
    /// 刻意不用 `NumberFormatter`：它不是 `Sendable`，放进 `static let` 会破坏
    /// Swift 6 严格并发；而这里只需要「最多一位小数」这一种格式。
    ///
    /// - Parameter value: 0...10 的评分。
    /// - Returns: `"8"` / `"7.5"` 这样的字符串。
    private static func formatRating(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(format: "%.1f", rounded)
    }

    /// 解析 `1990-2024` 形式的年份区间。
    ///
    /// - Parameter raw: 原始字符串。
    /// - Returns: 闭区间；格式非法或上下界颠倒时为 `nil`。
    private static func parseYearRange(_ raw: String?) -> ClosedRange<Int>? {
        guard let raw else { return nil }
        let parts = raw.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2,
              let lower = Int(parts[0]),
              let upper = Int(parts[1]),
              lower <= upper
        else { return nil }
        return lower...upper
    }
}
