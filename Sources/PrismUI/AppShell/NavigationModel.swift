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
/// 这是应用外壳的唯一导航状态源，负责：
/// - 侧边栏选中项（``selection``）与内容栏路由（``contentRoute``）；
/// - 详情页栈（``detailPath``）与返回；
/// - 播放器覆盖层（``isPlayerPresented``）；
/// - 侧边栏可见性（``isSidebarVisible``）；
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

    /// 侧边栏是否显示。
    public var isSidebarVisible: Bool

    /// 详情页的导航栈。空表示当前展示一级内容，非空表示主内容栏展示详情。
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

    /// 已保存的服务器列表。
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

    /// 当前内容栏正在展示的一级路由。
    ///
    /// 侧边栏只有固定的「电影 / 剧集」两项，但首页可以展示服务器返回的任意媒体库。
    /// 只保存 `selection` 会丢掉自定义媒体库的真实 id，因此这里保留完整路由作为覆盖值。
    /// 离开该媒体库时清除；详情和播放器仍然通过 `detailPath` / `playerRoute` 管理。
    public private(set) var activeRootRoute: Route?

    /// 已加载媒体库的展示名称，key 为服务端 view id。
    ///
    /// `Route` 只保存 id 与类型，名称由导航模型单独缓存供筛选栏显示。
    public var libraryNames: [String: String]

    /// 退出登录请求。认证模块接入后由上层赋值。
    public var onSignOut: (() -> Void)?

    /// 切换服务器请求。由根层负责重新认证并重建 ``PrismSession``。
    public var onSelectServer: ((String) -> Void)?
    /// 添加服务器请求。
    public var onAddServer: (() -> Void)?

    // MARK: 布局状态

    /// 窗口内容宽度（由 ``AppShellView`` 通过 `onGeometryChange` 回写）。
    public private(set) var windowWidth: CGFloat

    /// 保留的布局兼容状态；详情页不再单独占列。
    public var isDetailColumnCollapsed: Bool

    /// 请求聚焦搜索框的计数器；每次自增，视图监听后把焦点交给搜索框。
    public private(set) var searchFocusRequest: Int

    /// 请求把焦点交给搜索结果区的计数器；每次自增。
    ///
    /// 用途：搜索框有焦点时按 ↓，`AppShellView` 自增它，
    /// `SearchView` 监听后让结果区获得焦点，之后 ↑↓/↵ 就能操作结果。
    public private(set) var resultsFocusRequest: Int

    // MARK: 常量

    /// 旧版详情列的宽度阈值，保留以兼容外部调用。
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
        self.isSidebarVisible = true
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
        self.activeRootRoute = nil
        self.libraryNames = [:]
        self.onSelectServer = nil
        self.onAddServer = nil
        self.windowWidth = 1280
        self.isDetailColumnCollapsed = false
        self.searchFocusRequest = 0
        self.resultsFocusRequest = 0
    }

    // MARK: 派生状态

    /// 内容栏当前应展示的路由。
    ///
    /// 设置页需要保留用户选中的 tab，因此不能直接使用 `selection.route`。
    public var contentRoute: Route {
        // 详情页复用主内容栏，不再占用第三列。根路由仍保留在
        // `activeRootRoute` / `selection` 中，返回时只需弹出这一层即可。
        if let detail = detailPath.last {
            return detail
        }

        if let activeRootRoute {
            return activeRootRoute
        }

        guard let selection else { return .home }
        switch selection {
        case .settings: return .settings(settingsTab)
        default: return route(for: selection)
        }
    }

    /// 当前主页面路由；详情以覆盖层显示时保持原页面不变。
    public var rootContentRoute: Route {
        if let activeRootRoute { return activeRootRoute }
        guard let selection else { return .home }
        switch selection {
        case .settings: return .settings(settingsTab)
        default: return route(for: selection)
        }
    }

    /// 媒体库路由的展示名称；尚未加载元数据时退回路由默认标题。
    public func libraryTitle(for route: Route) -> String {
        guard case let .library(id, _) = route else { return route.title }
        return libraryNames[id] ?? route.title
    }

    /// 窗口标题：播放时固定「正在播放」，否则用当前页面标题（媒体库取服务端库名）。
    public var windowTitle: String {
        isPlayerPresented ? "正在播放" : libraryTitle(for: contentRoute)
    }

    /// 注册一个服务端媒体库的完整路由。
    ///
    /// 电影 / 剧集库同步到固定侧边栏项；其他库仍可通过首页的完整路由打开。
    public func registerLibraryRoute(_ route: Route, name: String) {
        guard case let .library(id, _) = route else { return }
        libraryNames[id] = name
        if let sidebarItem = route.sidebarItem {
            libraryRoutes[sidebarItem] = route
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

    /// 兼容旧菜单接口；详情页现在直接占满内容栏，因此没有可切换的详情栏。
    public var canToggleDetailColumn: Bool {
        false
    }

    /// 兼容旧布局状态查询；当前详情页始终在内容栏展示。
    public var showsDetailColumn: Bool {
        false
    }

    /// 窗口是否处于旧版详情列的紧凑宽度。
    public var isCompactWidth: Bool {
        windowWidth < Self.detailColumnMinimumWindowWidth
    }

    /// 侧边栏是否可见。
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

    /// 选中侧边栏导航项，并按 IA 规则更新内容栏与详情页。
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
    /// - ``Route/detail(itemId:)`` 会替换详情栈为单条详情，并在主内容栏全宽展示；
    /// - ``Route/player(itemId:mediaSourceId:resumeAt:)`` 会打开播放器覆盖层。
    ///
    /// - Parameter route: 目标路由。
    public func navigate(to route: Route) {
        isServerSwitcherPresented = false

        switch route {
        case .home, .search, .downloads, .settings:
            selection = route.sidebarItem
            activeRootRoute = nil
            detailPath = []
            if case let .settings(tab) = route {
                settingsTab = tab
            }
            if case .search = route {
                focusSearch()
            }
        case .library:
            // 保留完整路由：媒体库可能是服务端自定义视图，不能拿侧边栏的占位 id 重建。
            //
            // 没有侧边栏归属的库（合集 / 音乐 / 图书…）要把选中项清空：
            // 否则侧边栏会继续高亮「首页」，用户看到的是「首页被选中、内容却是合集库」。
            selection = route.sidebarItem
            activeRootRoute = route
            detailPath = []
        case .detail:
            detailPath = [route]
            isDetailColumnCollapsed = false
        case let .player(itemId, mediaSourceId, resumeAt):
            presentPlayer(itemId: itemId, mediaSourceId: mediaSourceId, resumeAt: resumeAt)
        }
    }

    /// 压入一条详情（用于「更多相似」「查看全部」等后续工单）。
    ///
    /// 与 ``navigate(to:)`` 一样，详情页会在主内容栏展示。
    ///
    /// - Parameter itemId: 条目 id。
    public func pushDetail(itemId: String) {
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

    /// 关闭播放器覆盖层，回到原来的内容界面。
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

    /// 请求把焦点交给搜索结果区。
    ///
    /// 由 `AppShellView` 在「搜索框有焦点且按下 ↓」时调用；
    /// `SearchView` 监听 ``resultsFocusRequest`` 的变化。
    public func requestResultsFocus() {
        resultsFocusRequest &+= 1
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
        // 直接敲搜索框不会经过 `navigate(to:)`，必须在这里清掉媒体库覆盖路由，
        // 否则内容栏仍然停在刚才那个媒体库上，搜索结果永远显示不出来。
        activeRootRoute = nil
    }

    // MARK: 列与窗口

    /// 切换侧边栏显示 / 隐藏。
    ///
    /// 显示或隐藏固定宽度的侧栏。
    public func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    /// 旧版详情栏切换接口；当前详情页始终占满内容栏。
    public func toggleDetailColumn() {
        // 详情页已经是内容栏内的全宽页面，保留方法以兼容菜单/外部调用。
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
        guard serverID != currentServerID else {
            isServerSwitcherPresented = false
            return
        }
        guard !serverStates.values.contains(.connecting) else { return }
        // 有运行时切换回调时，先保持当前会话和内容不变，等待根层认证成功后
        // 用新的 PrismSession 重建外壳；否则会出现胶囊显示 B、请求仍发往 A 的错配。
        if let onSelectServer {
            serverStates[serverID] = .connecting
            isServerSwitcherPresented = false
            onSelectServer(serverID)
            return
        }

        applyServerSelection(serverID)
        isServerSwitcherPresented = false
    }

    private func applyServerSelection(_ serverID: String) {
        currentServerID = serverID
        selection = .home
        detailPath = []
        // 媒体库 id 与名称都属于上一台服务器，必须一起清掉，
        // 否则新服务器会用旧 view id 发请求（通常返回空库或 404）。
        activeRootRoute = nil
        libraryRoutes = [:]
        libraryNames = [:]
    }

    /// 在运行时服务器认证成功后提交导航状态。
    public func completeServerSelection(id serverID: String) {
        guard servers.contains(where: { $0.id == serverID }) else { return }
        serverStates[serverID] = .connected
        applyServerSelection(serverID)
    }

    /// 标记服务器切换失败，当前服务器与会话保持不变。
    public func failServerSelection(id serverID: String, status: ServerStatus = .offline) {
        serverStates[serverID] = status
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
