import SwiftUI

// MARK: - 应用外壳

/// 应用主窗口的三栏外壳。
///
/// 结构（`docs/research/ux-benchmark.md` §2.2）：
/// - **侧边栏**：媒体库 / 工具 / 底部固定区（设置 + 服务器胶囊）；
/// - **内容栏**：随 ``NavigationModel/contentRoute`` 切换；
/// - **详情栏**：媒体库路由下显示条目详情或空态；首页 / 搜索 / 设置下收起。
///
/// 只有一个 `NavigationSplitView`，不存在「两套壳」：
/// 详情栏的显隐由「列宽收为 0」实现，而不是切换 `.doubleColumn`。
/// 原因（已用 macOS 26 SDK 实测）：三栏 `NavigationSplitView` 的
/// `.doubleColumn` 语义是「内容栏 + 详情栏」，会把**侧边栏**藏掉；
/// 用它来隐藏详情栏会导致首页没有导航。`columnVisibility` 因此只负责侧边栏，
/// 详情栏由 ``NavigationModel/showsDetailColumn`` 控制。
///
/// 工具栏（§4.2）：leading 返回、trailing 搜索框与详情栏切换；
/// 搜索框通过 `.searchable(placement: .toolbar)` 常驻工具栏，⌘F 聚焦。
/// 播放器以覆盖层呈现（v1.0 全窗口播放页），不塞进详情栏。
public struct AppShellView: View {
    /// 导航模型（由 ``RootShell`` 注入并共享给菜单命令）。
    @Bindable private var model: NavigationModel

    /// 当前会话；`nil` 表示未登录（页面降级为占位）。
    private let session: PrismSession?

    /// 工具栏搜索框焦点。
    @FocusState private var isSearchFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 创建应用外壳。
    ///
    /// - Parameters:
    ///   - model: 导航模型。
    ///   - session: 已登录会话；`nil` 时各页面显示「未连接」占位。
    public init(model: NavigationModel, session: PrismSession? = nil) {
        self.model = model
        self.session = session
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $model.columnVisibility) {
            SidebarView(model: model)
        } content: {
            ContentColumnView(model: model, session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.surface)
                .navigationSplitViewColumnWidth(min: 420, ideal: 720)
        } detail: {
            detailColumn
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 960, minHeight: 600)
        .navigationTitle(model.isPlayerPresented ? "正在播放" : model.contentRoute.title)
        .toolbar { toolbarContent }
        .toolbarVisibility(model.isPlayerPresented ? .hidden : .automatic, for: .windowToolbar)
        .searchable(
            text: $model.searchText,
            placement: .toolbar,
            prompt: Text("搜索影片、剧集、演员")
        )
        .searchFocused($isSearchFocused)
        .onChange(of: model.searchFocusRequest) { _, _ in
            isSearchFocused = true
        }
        .onChange(of: model.searchText) { _, _ in
            model.searchTextDidChange()
        }
        // 搜索框有焦点时，↓ 把焦点交给结果区（否则方向键被文本框吃掉，
        // 用户没法用键盘选结果）。结果区内部的 ↑↓/↵ 由 `SearchView` 自己处理。
        .onKeyPress(.downArrow) {
            guard isSearchFocused, model.contentRoute == .search, !model.searchText.isEmpty else {
                return .ignored
            }
            isSearchFocused = false
            model.requestResultsFocus()
            return .handled
        }
        .onExitCommand {
            // Esc = 返回：先关播放器，再弹详情栈；不直接关窗口（§4.6.5 第 2 条）。
            model.goBack()
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            model.updateWindowWidth(width)
        }
        .overlay {
            playerOverlay
        }
        .animation(playerAnimation, value: model.isPlayerPresented)
    }

    // MARK: 详情栏

    /// 详情栏：需要时显示详情 / 空态，不需要时把列宽收为 0（侧边栏保持可见）。
    @ViewBuilder
    private var detailColumn: some View {
        if model.showsDetailColumn {
            DetailColumnView(model: model, session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.surface)
                .navigationSplitViewColumnWidth(min: 380, ideal: 640)
        } else {
            Color.clear
                .navigationSplitViewColumnWidth(0)
                .accessibilityHidden(true)
        }
    }

    // MARK: 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                model.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!model.canGoBack)
            .help("返回（⌘[）")
            .accessibilityLabel("返回")
        }

        if model.canToggleDetailColumn {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.toggleDetailColumn()
                } label: {
                    Image(systemName: model.showsDetailColumn ? "rectangle.split.3x1" : "rectangle.split.2x1")
                }
                .help(model.showsDetailColumn ? "隐藏详情栏" : "显示详情栏")
                .accessibilityLabel(model.showsDetailColumn ? "隐藏详情栏" : "显示详情栏")
            }
        }
    }

    // MARK: 播放器覆盖层

    @ViewBuilder
    private var playerOverlay: some View {
        if model.isPlayerPresented {
            PlayerPlaceholderView(route: model.playerRoute) {
                model.dismissPlayer()
            }
            .transition(.opacity)
            .zIndex(1)
        }
    }

    /// 播放器出现 / 消失的动画；尊重「减弱动态效果」。
    private var playerAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: Motion.standard)
    }
}

// MARK: - 内容栏

/// 内容栏：根据当前路由展示对应页面。
///
/// 本工单只接占位视图；后续工单把 `switch` 的分支替换成真实页面即可，
/// 外壳与导航模型不需要改动。
private struct ContentColumnView: View {
    /// 导航模型。
    @Bindable var model: NavigationModel

    /// 当前会话；`nil` 时各页面降级为占位。
    let session: PrismSession?

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch model.contentRoute {
        case .home:
            if let session {
                HomeView(
                    model: HomeViewModel(
                        dataSource: session.isDemo
                            ? DemoDataSources.Home()
                            : session.homeDataSource
                    ),
                    // 不传 accessToken：图片走 `EmbyImageLoader` 的鉴权头，
                    // 令牌不进 URL（详见 `PrismSession.detailDataSource` 的说明）。
                    imageResolver: HomeImageResolver(
                        baseURL: session.server.baseURL,
                        accessToken: nil
                    ),
                    onNavigate: { route in model.navigate(to: route) }
                )
            } else {
                HomePlaceholderView()
            }
        case let .library(id, type):
            if let session {
                LibraryView(
                    viewModel: LibraryViewModel(
                        dataSource: session.isDemo
                            ? DemoDataSources.Library()
                            : session.libraryDataSource,
                        libraryId: id,
                        // `MediaKind` 是 Emby 的媒体大类（Video/Audio/Photo/Book），
                        // 不是「电影/剧集」。电影与剧集都属于 Video，具体类型用
                        // `includeItemTypes` 区分。
                        kind: .video,
                        includeItemTypes: type == .series ? [.series] : [.movie]
                    ),
                    libraryName: model.contentRoute.title,
                    countUnit: type == .series ? "部" : "部",
                    selectedItemID: model.selectedDetailItemID,
                    onOpenDetail: { item in model.navigate(to: .detail(itemId: item.id)) },
                    onPlay: { item in
                        model.navigate(to: .player(itemId: item.id, mediaSourceId: nil, resumeAt: .zero))
                    }
                )
            } else {
                LibraryPlaceholderView(libraryID: id, type: type)
            }
        case .search:
            if let session {
                SearchView(
                    viewModel: SearchViewModel(
                        dataSource: session.isDemo
                            ? DemoDataSources.Search()
                            : session.searchDataSource
                    ),
                    navigation: model,
                    onOpen: { result in
                        model.navigate(to: .detail(itemId: result.id))
                    },
                    onPlay: { result in
                        model.navigate(to: .player(itemId: result.id, mediaSourceId: nil, resumeAt: .zero))
                    }
                )
            } else {
                SearchPlaceholderView()
            }
        case .downloads:
            DownloadsPlaceholderView()
        case let .settings(tab):
            SettingsPlaceholderView(tab: tab)
        case .detail:
            // 详情属于详情栏，内容栏不应出现该路由；保底给空态。
            DetailEmptyView()
        case .player:
            // 播放器是覆盖层，内容栏保持原页面。
            Color.clear
        }
    }
}

// MARK: - 详情栏

/// 详情栏：展示当前选中条目的详情占位，未选中时显示空态。
private struct DetailColumnView: View {
    /// 导航模型。
    @Bindable var model: NavigationModel

    /// 当前会话；`nil` 时降级为占位。
    let session: PrismSession?

    var body: some View {
        if let itemID = model.selectedDetailItemID {
            if let session {
                // `DetailScreen` 内部用 `@State` 持有 ViewModel 并自己按类型分派，
                // 分支切换发生在稳定视图内部，不会因 View 类型变化重新种子化。
                // `.id(itemID)` 是必须的：换条目要重建状态，否则会继续显示上一个条目。
                DetailScreen(
                    model: DetailViewModel(
                        dataSource: session.isDemo
                            ? DemoDataSources.Detail()
                            : session.detailDataSource,
                        itemId: itemID
                    ),
                    actions: DetailActions(
                        play: { request in
                            model.navigate(to: .player(
                                itemId: request.itemId,
                                mediaSourceId: request.mediaSourceId,
                                resumeAt: request.resumeAt
                            ))
                        },
                        openItem: { id in
                            model.navigate(to: .detail(itemId: id))
                        }
                    )
                )
                .id(itemID)
            } else {
                DetailPlaceholderView(itemId: itemID)
            }
        } else {
            DetailEmptyView()
        }
    }
}
