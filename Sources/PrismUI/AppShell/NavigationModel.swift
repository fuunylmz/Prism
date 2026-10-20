import PrismCore
import SwiftUI

// MARK: - 服务器状态

/// 服务器胶囊上展示的连接状态。
///
/// 状态语义来自 `docs/research/ux-benchmark.md` §2.4；颜色由视图层决定，
/// 模型层只保存状态本身，避免把 AppKit / 颜色类型带进导航模型。
public enum ServerStatus: String, Hashable, Sendable, CaseIterable {
    /// 已连接。
    case connected
    /// 连接中（胶囊显示脉冲点）。
    case connecting
    /// 令牌失效，需要重新登录。
    case unauthorized
    /// 离线。
    case offline
    /// 服务器版本不受支持。
    case unsupported

    /// 面向用户的状态文案。
    public var title: String {
        switch self {
        case .connected: "已连接"
        case .connecting: "正在连接…"
        case .unauthorized: "需要重新登录"
        case .offline: "离线"
        case .unsupported: "服务器版本不受支持"
        }
    }

    /// 状态是否可交互（已连接 / 连接中视为可用）。
    public var isUsable: Bool {
        self == .connected || self == .connecting
    }
}

// MARK: - 导航模型

/// 应用外壳的导航状态。
///
/// 这是三栏 `NavigationSplitView` 的唯一状态源，负责：
/// - 侧边栏选中项（``selection``）与内容栏路由（``contentRoute``）；
/// - 详情栏栈（``detailPath``）与返回；
/// - 播放器覆盖层（``isPlayerPresented``）；
/// - 列可见性（``columnVisibility`` / ``showsDetailColumn``）；
/// - 当前服务器与用户（供服务器胶囊展示与切换）。
///
/// **边界**：本类型只依赖 SwiftUI 与 PrismCore，不持有 `EmbyClient`、
/// 不发起任何网络请求、不做持久化。服务器 / 用户数据由上层注入；
/// 退出登录等动作通过 ``onSignOut`` 回调交给认证模块。
///
/// 所有属性均在主线程访问；视图通过 `@Bindable` 绑定。
@MainActor
@Observable
public final class NavigationModel {
    // MARK: 导航状态

    /// 侧边栏当前选中项。`nil` 表示未选中（启动时默认 ``SidebarItem/home``）。
    public var selection: SidebarItem?

    /// 三栏的列可见性。
    ///
    /// 注意：在**三栏** `NavigationSplitView` 中，`.doubleColumn` 表示
    /// 「内容栏 + 详情栏」（隐藏侧边栏），而不是「侧边栏 + 内容栏」。因此外壳
    /// **不**用 `.doubleColumn` 隐藏详情栏，而是用 ``showsDetailColumn``
    /// 把详情栏宽度收为 0；`columnVisibility` 只用于侧边栏的显示 / 隐藏。
    public var columnVisibility: NavigationSplitViewVisibility

    /// 详情栏的导航栈。空表示未选中任何条目（显示空态）。
    public var detailPath: [Route]

    /// 播放器覆盖层是否可见。
    public var isPlayerPresented: Bool

    /// 播放器当前播放的路由（``Route/player(itemId:mediaSourceId:resumeAt:)``）。
    public private(set) var playerRoute: Route?

    /// 工具栏搜索框的文本。
    public var searchText: String

    /// 设置面板当前选中的 tab。
    public var settingsTab: SettingsTab

    // MARK: 服务器与用户

    /// 已保存的服务器列表（v1.0 通常只有一台）。
    public var servers: [ServerConnection]

    /// 当前服务器 id；`nil` 时取 ``servers`` 的第一台。
    public var currentServerID: String?

    /// 当前登录用户；未登录为 `nil`。
    public var currentUser: EmbyUser?

    /// 各服务器的连接状态（key 为服务器 id）。
    public var serverStates: [String: ServerStatus]

    /// 服务器切换浮层是否展开（服务器胶囊点击 / ⌘⇧S）。
    public var isServerSwitcherPresented: Bool

    /// 媒体库侧边栏项到真实路由的映射（注入点）。
    ///
    /// v1.0 的外壳拿不到服务端视图 id，``SidebarItem/route`` 给出的是占位路由；
    /// 媒体库模块拿到 `/Users/{id}/Views` 之后，把真实 id 写进这里即可，
    /// 外壳代码不需要改动。未注入的项回落到 ``SidebarItem/route``。
    public var libraryRoutes: [SidebarItem: Route]

    /// 退出登录请求。认证模块接入后由上层赋值。
    public var onSignOut: (() -> Void)?

    // MARK: 布局状态

    /// 窗口内容宽度（由 ``AppShellView`` 通过 `onGeometryChange` 回写）。
    public private(set) var windowWidth: CGFloat

    /// 用户是否手动折叠了详情栏（工具栏按钮 / 显示菜单）。
    public var isDetailColumnCollapsed: Bool

    /// 请求聚焦搜索框的计数器；每次自增，视图监听后把焦点交给搜索框。
    public private(set) var searchFocusRequest: Int

    // MARK: 常量

    /// 详情栏自动折叠的窗口宽度阈值。
    ///
    /// 低于该宽度时三栏放不下（侧边栏 220 + 内容栏 480 + 详情栏 420），
    /// 自动隐藏详情栏，保留返回按钮（见 `docs/research/ux-benchmark.md` §4.1）。
    public static let detailColumnMinimumWindowWidth: CGFloat = 1040

    // MARK: 初始化

    /// 创建导航模型。
    ///
    /// - Parameters:
    ///   - selection: 初始侧边栏选中项，默认首页。
    ///   - servers: 已保存的服务器列表，默认空。
    ///   - currentServerID: 当前服务器 id，默认取列表第一台。
    ///   - currentUser: 当前用户，默认未登录。
    public init(
        selection: SidebarItem? = .home,
        servers: [ServerConnection] = [],
        currentServerID: String? = nil,
        currentUser: EmbyUser? = nil
    ) {
        self.selection = selection
        self.columnVisibility = .all
        self.detailPath = []
        self.isPlayerPresented = false
        self.playerRoute = nil
        self.searchText = ""
        self.settingsTab = .playback
        self.servers = servers
        self.currentServerID = currentServerID ?? servers.first?.id
        self.currentUser = currentUser
        self.serverStates = [:]
        self.isServerSwitcherPresented = false
        self.libraryRoutes = [:]
        self.windowWidth = 1280
        self.isDetailColumnCollapsed = false
        self.searchFocusRequest = 0
    }

    // MARK: 派生状态

    /// 内容栏当前应展示的路由。
    ///
    /// 设置页需要保留用户选中的 tab，因此不能直接使用 `selection.route`。
    public var contentRoute: Route {
        guard let selection else { return .home }
        switch selection {
        case .settings: return .settings(settingsTab)
        default: return route(for: selection)
        }
    }

    /// 侧边栏项对应的实际路由（优先使用 ``libraryRoutes`` 注入的真实库 id）。
    ///
    /// - Parameter item: 侧边栏导航项。
    /// - Returns: 该导航项应展示的路由。
    public func route(for item: SidebarItem) -> Route {
        libraryRoutes[item] ?? item.route
    }

    /// 当前服务器；未设置 ``currentServerID`` 时回落到列表第一台。
    public var currentServer: ServerConnection? {
        if let currentServerID, let match = servers.first(where: { $0.id == currentServerID }) {
            return match
        }
        return servers.first
    }

    /// 服务器胶囊上显示的服务器名。
    public var currentServerName: String {
        currentServer?.name ?? "未连接服务器"
    }

    /// 服务器胶囊上显示的用户名。
    public var currentUserName: String {
        currentUser?.name ?? "未登录"
    }

    /// 当前服务器的连接状态。
    public var currentServerStatus: ServerStatus {
        guard let id = currentServer?.id else { return .offline }
        return status(for: id)
    }

    /// 是否保存了多台服务器（决定胶囊是否显示切换箭头）。
    public var hasMultipleServers: Bool {
        servers.count > 1
    }

    /// 是否可以返回（播放器或详情栈中还有内容）。
    public var canGoBack: Bool {
        isPlayerPresented || !detailPath.isEmpty
    }

    /// 当前路由是否支持详情栏（只有媒体库支持）。
    public var canToggleDetailColumn: Bool {
        contentRoute.showsDetailColumn
    }

    /// 详情栏此刻是否应该显示。
    ///
    /// 三个条件同时满足才显示：路由需要详情栏、用户没有手动折叠、窗口足够宽。
    public var showsDetailColumn: Bool {
        canToggleDetailColumn
            && !isDetailColumnCollapsed
            && windowWidth >= Self.detailColumnMinimumWindowWidth
    }

    /// 窗口是否处于「放不下三栏」的紧凑宽度。
    public var isCompactWidth: Bool {
        windowWidth < Self.detailColumnMinimumWindowWidth
    }

    /// 侧边栏是否可见。
    public var isSidebarVisible: Bool {
        columnVisibility == .all
    }

    /// 详情栏当前栈顶的条目 id（用于详情占位视图）。
    public var selectedDetailItemID: String? {
        detailPath.last?.detailItemID
    }

    /// 某台服务器的连接状态。
    ///
    /// - Parameter serverID: 服务器 id。
    /// - Returns: 显式记录的状态；未记录时当前服务器视为已连接、其余视为离线。
    public func status(for serverID: String) -> ServerStatus {
        if let recorded = serverStates[serverID] { return recorded }
        return serverID == currentServer?.id ? .connected : .offline
    }

    // MARK: 导航

    /// 选中侧边栏导航项，并按 IA 规则更新内容栏与详情栏。
    ///
    /// 禁用项（v1.0 的下载）会被忽略。
    ///
    /// - Parameter item: 要选中的导航项。
    public func select(_ item: SidebarItem) {
        guard item.isAvailable else { return }
        if item == .settings {
            navigate(to: .settings(settingsTab))
        } else {
            navigate(to: route(for: item))
        }
    }

    /// 导航到指定路由。
    ///
    /// 规则：
    /// - 一级导航（首页 / 媒体库 / 搜索 / 下载 / 设置）会替换内容栏根视图，
    ///   并清空详情栈（侧边栏切换不 push）；
    /// - ``Route/detail(itemId:)`` 会替换详情栈为单条详情，**仅在当前路由有详情栏时生效**
    ///   （首页 / 搜索 / 设置是 `.doubleColumn`，没有第三栏可放详情；搜索结果的条目
    ///   应由搜索工单在内容栏内 push，而不是走详情栏）；
    /// - ``Route/player(itemId:mediaSourceId:resumeAt:)`` 会打开播放器覆盖层。
    ///
    /// - Parameter route: 目标路由。
    public func navigate(to route: Route) {
        isServerSwitcherPresented = false

        switch route {
        case .home, .library, .search, .downloads, .settings:
            selection = route.sidebarItem
            detailPath = []
            if case let .settings(tab) = route {
                settingsTab = tab
            }
            if case .search = route {
                focusSearch()
            }
        case .detail:
            guard canToggleDetailColumn else { return }
            detailPath = [route]
            // 用户主动打开详情时，确保详情栏没有被折叠掉。
            isDetailColumnCollapsed = false
        case let .player(itemId, mediaSourceId, resumeAt):
            presentPlayer(itemId: itemId, mediaSourceId: mediaSourceId, resumeAt: resumeAt)
        }
    }

    /// 在详情栏压入一条详情（用于「更多相似」「查看全部」等后续工单）。
    ///
    /// 与 ``navigate(to:)`` 一样，只有当前路由带详情栏时才生效。
    ///
    /// - Parameter itemId: 条目 id。
    public func pushDetail(itemId: String) {
        guard canToggleDetailColumn else { return }
        detailPath.append(.detail(itemId: itemId))
        isDetailColumnCollapsed = false
    }

    /// 返回上一级。
    ///
    /// 顺序：先关闭播放器，再弹出详情栈；两者都为空时不做任何事。
    /// 对应菜单命令 ⌘[ 与播放器外的 `Esc`。
    public func goBack() {
        if isPlayerPresented {
            dismissPlayer()
            return
        }
        if !detailPath.isEmpty {
            detailPath.removeLast()
        }
    }

    // MARK: 播放器

    /// 打开播放器覆盖层。
    ///
    /// - Parameters:
    ///   - itemId: 条目 id。
    ///   - mediaSourceId: 指定媒体源；`nil` 表示自动协商。
    ///   - resumeAt: 起播位置，默认从头开始。
    public func presentPlayer(
        itemId: String,
        mediaSourceId: String? = nil,
        resumeAt: Ticks = .zero
    ) {
        playerRoute = .player(itemId: itemId, mediaSourceId: mediaSourceId, resumeAt: resumeAt)
        isPlayerPresented = true
    }

    /// 关闭播放器覆盖层，回到原来的三栏界面。
    public func dismissPlayer() {
        isPlayerPresented = false
        playerRoute = nil
    }

    // MARK: 搜索

    /// 请求工具栏搜索框获得焦点。
    ///
    /// 视图监听 ``searchFocusRequest`` 的变化；⌘F 与点击侧边栏「搜索」都会调用它。
    public func focusSearch() {
        searchFocusRequest &+= 1
    }

    /// 搜索文本变化时的导航副作用。
    ///
    /// 一旦输入非空关键词，内容栏切到搜索路由（不重复抢焦点）。
    public func searchTextDidChange() {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        if selection != .search {
            selection = .search
            detailPath = []
        }
    }

    // MARK: 列与窗口

    /// 切换侧边栏显示 / 隐藏。
    ///
    /// 三栏 `NavigationSplitView` 中 `.doubleColumn` 即「隐藏侧边栏」。
    public func toggleSidebar() {
        columnVisibility = columnVisibility == .all ? .doubleColumn : .all
    }

    /// 切换详情栏显示 / 隐藏（仅媒体库路由可用）。
    public func toggleDetailColumn() {
        guard canToggleDetailColumn else { return }
        isDetailColumnCollapsed.toggle()
    }

    /// 窗口宽度变化时由视图回写。
    ///
    /// - Parameter width: 窗口内容宽度（pt）。
    public func updateWindowWidth(_ width: CGFloat) {
        guard width > 0, width != windowWidth else { return }
        windowWidth = width
    }

    // MARK: 服务器

    /// 切换当前服务器。
    ///
    /// 按 §2.4 的约定：切换不销毁窗口，只替换数据源，侧边栏选中项回落到首页；
    /// 正在播放的会话不受影响（播放器绑定旧服务器）。
    ///
    /// - Parameter serverID: 目标服务器 id；不存在时忽略。
    public func selectServer(id serverID: String) {
        guard servers.contains(where: { $0.id == serverID }) else { return }
        currentServerID = serverID
        selection = .home
        detailPath = []
        isServerSwitcherPresented = false
    }

    /// 打开设置窗口 / 面板。
    ///
    /// - Parameter tab: 目标面板，默认播放。
    public func openSettings(_ tab: SettingsTab = .playback) {
        navigate(to: .settings(tab))
    }

    /// 请求退出登录，交由上层认证模块处理。
    public func requestSignOut() {
        isServerSwitcherPresented = false
        onSignOut?()
    }
}
