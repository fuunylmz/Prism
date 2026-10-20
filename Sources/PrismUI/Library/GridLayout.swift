import Foundation

// MARK: - 网格布局

/// 媒体库内容区的两种排布方式。
///
/// 来源：`docs/research/ux-benchmark.md` §S05「视图切换（网格 / 列表）」与
/// §4.2「center：视图切换（网格 / 列表）、筛选、排序」。
///
/// 两种布局共用同一份数据与同一套键盘语义（↑↓←→ 移动、↵ 详情、空格播放），
/// 只有排布与信息密度不同：
/// - ``poster``：海报墙，2:3 海报 + 标题，用于「扫视」；
/// - ``list``：紧凑行（海报缩略图 + 标题 + 年份 + 时长 + 简介），用于「快速浏览」，
///   条目很多或标题很长时更好用。
///
/// 原始值用于 v1.1 深链与偏好持久化，**不得改名**。
public enum GridLayout: String, Sendable, Hashable, CaseIterable, Codable, Identifiable {
    /// 海报网格（默认）。
    case poster
    /// 紧凑列表。
    case list

    /// `Identifiable` 要求的稳定 id。
    public var id: String { rawValue }

    /// 菜单 / 按钮上的文案。
    public var title: String {
        switch self {
        case .poster: "网格"
        case .list: "列表"
        }
    }

    /// 对应的 SF Symbol 名称。
    ///
    /// 用 `square.grid.2x2` 与 `list.bullet` 这一对长期存在的符号，
    /// 避免 macOS 版本差异导致的图标缺失。
    public var systemImage: String {
        switch self {
        case .poster: "square.grid.2x2"
        case .list: "list.bullet"
        }
    }

    /// 另一种布局（用于单按钮切换）。
    public var toggled: GridLayout {
        switch self {
        case .poster: .list
        case .list: .poster
        }
    }
}
