import PrismCore

// MARK: - 路由

/// 应用内的导航目标。
///
/// 这是 `docs/ARCHITECTURE.md` §5.2 的**冻结契约**：签名由架构文档定义，
/// 任何页面（首页、媒体库、搜索、设置、详情、播放器）都通过它被寻址，
/// 以便后续工单在不改动外壳的前提下接入真实页面。
///
/// 约定：
/// - 侧边栏一级导航只产生 ``home`` / ``library(id:type:)`` / ``search`` /
///   ``downloads`` / ``settings(_:)``；
/// - 条目详情属于**详情栏**，用 ``detail(itemId:)`` 表示，不进侧边栏导航栈；
/// - 播放器是覆盖层（v1.0 为全窗口播放页），用 ``player(itemId:mediaSourceId:resumeAt:)``
///   表示，不占三栏中的任何一栏。
public enum Route: Hashable, Sendable {
    /// 首页：继续观看 / 接下来 / 最近添加。
    case home
    /// 某个服务端媒体库的网格。
    ///
    /// - Parameters:
    ///   - id: 服务端视图 id（Emby `/Users/{id}/Views` 返回的 `Id`）。
    ///   - type: 库的内容类型，决定标题、图标与网格形态。
    case library(id: String, type: ItemType)
    /// 搜索落地页与结果页。
    case search
    /// 下载管理（v1.1；v1.0 侧边栏以禁用态展示）。
    case downloads
    /// 设置窗口中的一个面板。
    case settings(SettingsTab)
    /// 条目详情（电影 / 剧集 / 单集）。
    case detail(itemId: String)
    /// 播放器覆盖层。
    ///
    /// - Parameters:
    ///   - itemId: 要播放的条目 id。
    ///   - mediaSourceId: 指定媒体源；`nil` 表示由播放器自行协商。
    ///   - resumeAt: 起播位置（续播点）；新片为 ``Ticks/zero``。
    case player(itemId: String, mediaSourceId: String?, resumeAt: Ticks)
}

// MARK: - 设置面板

/// 设置窗口的面板。
///
/// 顺序与 `docs/research/ux-benchmark.md` §S15 对齐：播放、字幕、网络、外观、
/// 服务器、关于。`CaseIterable` 的顺序即设置窗口侧栏的显示顺序。
public enum SettingsTab: Hashable, Sendable, CaseIterable {
    /// 播放：画质、自动下一集、硬件解码等。
    case playback
    /// 字幕：语言、字号、样式、延迟。
    case subtitles
    /// 网络：超时、并发、缓存、代理。
    case network
    /// 外观：主题、海报尺寸、动效。
    case appearance
    /// 服务器：列表、重命名、重新登录。
    case servers
    /// 关于：版本、致谢、开源许可、诊断。
    case about
}

// MARK: - 侧边栏一级导航

/// 侧边栏的一级导航项。
///
/// 只放「去处」，不放「功能」（见 `docs/research/ux-benchmark.md` §2.1）。
/// ``downloads`` 在 v1.0 以禁用态展示，v1.1 启用；``settings`` 固定渲染在
/// 侧边栏底部，不参与滚动。
public enum SidebarItem: Hashable, Sendable, CaseIterable {
    /// 首页。
    case home
    /// 电影库。
    case movies
    /// 剧集库。
    case series
    /// 搜索（点击后聚焦工具栏搜索框）。
    case search
    /// 下载管理（v1.1）。
    case downloads
    /// 设置。
    case settings
}

// MARK: - 展示元数据

extension SidebarItem {
    /// 侧边栏与菜单里显示的中文标题。
    public var title: String {
        switch self {
        case .home: "首页"
        case .movies: "电影"
        case .series: "剧集"
        case .search: "搜索"
        case .downloads: "下载"
        case .settings: "设置"
        }
    }

    /// 对应的 SF Symbol 名称。
    public var systemImage: String {
        switch self {
        case .home: "house"
        case .movies: "film"
        case .series: "tv"
        case .search: "magnifyingglass"
        case .downloads: "arrow.down.circle"
        case .settings: "gearshape"
        }
    }

    /// 该导航项在 v1.0 是否可用。
    ///
    /// 下载管理属于 v1.1 范围，v1.0 保留入口但禁用，避免用户误以为功能缺失。
    public var isAvailable: Bool {
        self != .downloads
    }

    /// 未上线功能的版本角标（例如 `"v1.1"`）；已上线为 `nil`。
    public var versionBadge: String? {
        switch self {
        case .downloads: "v1.1"
        default: nil
        }
    }

    /// 该导航项对应的路由。
    ///
    /// 电影 / 剧集库在 v1.0 先用稳定的占位 id；接入真实 `/Views` 数据后，
    /// 由媒体库模块把服务端视图 id 注入 ``NavigationModel``。
    public var route: Route {
        switch self {
        case .home: .home
        case .movies: .library(id: "library.movies", type: .movie)
        case .series: .library(id: "library.series", type: .series)
        case .search: .search
        case .downloads: .downloads
        case .settings: .settings(.playback)
        }
    }
}

extension SettingsTab {
    /// 设置面板标题。
    public var title: String {
        switch self {
        case .playback: "播放"
        case .subtitles: "字幕"
        case .network: "网络"
        case .appearance: "外观"
        case .servers: "服务器"
        case .about: "关于"
        }
    }

    /// 设置面板的 SF Symbol 名称。
    public var systemImage: String {
        switch self {
        case .playback: "play.rectangle"
        case .subtitles: "character.bubble"
        case .network: "network"
        case .appearance: "paintbrush"
        case .servers: "externaldrive.connected.to.line.below"
        case .about: "info.circle"
        }
    }
}

extension Route {
    /// 路由对应的窗口 / 内容栏标题（HIG 要求用当前库名，而不是 App 名）。
    public var title: String {
        switch self {
        case .home: "首页"
        case let .library(_, type):
            switch type {
            case .movie: "电影"
            case .series: "剧集"
            default: "媒体库"
            }
        case .search: "搜索"
        case .downloads: "下载"
        case let .settings(tab): tab.title
        case .detail: "详情"
        case .player: "正在播放"
        }
    }

    /// 该路由在侧边栏中对应的选中项；详情与播放器不改变侧边栏选中态。
    public var sidebarItem: SidebarItem? {
        switch self {
        case .home: .home
        case let .library(_, type):
            switch type {
            case .movie: .movies
            case .series: .series
            default: nil
            }
        case .search: .search
        case .downloads: .downloads
        case .settings: .settings
        case .detail, .player: nil
        }
    }

    /// 该路由是否需要详情栏。
    ///
    /// 首页 / 搜索 / 设置是「内容栏占满」的页面，不需要第三栏；
    /// 媒体库需要详情栏（即使尚未选中条目，也显示空态提示）。
    public var showsDetailColumn: Bool {
        switch self {
        case .library, .detail: true
        case .home, .search, .downloads, .settings, .player: false
        }
    }

    /// 若该路由是条目详情，返回条目 id；否则为 `nil`。
    public var detailItemID: String? {
        if case let .detail(itemId) = self { return itemId }
        return nil
    }
}
