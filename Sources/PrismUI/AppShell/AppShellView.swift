import PrismCore
import SwiftUI

// MARK: - 应用外壳

/// 应用主窗口的固定侧栏与内容区。
///
/// 结构（`docs/research/ux-benchmark.md` §2.2）：
/// - **侧边栏**：媒体库 / 工具 / 底部固定区（设置 + 服务器胶囊）；
/// - **主内容区**：根页面按路由切换，主页保持挂载，详情作为覆盖层显示；
///
/// 详情作为内容区覆盖层显示；底层主页面保持挂载，返回时不会重新创建或加载首页。
///
/// 工具栏（§4.2）：侧栏切换、返回与搜索框；
/// 搜索框通过 `.searchable(placement: .toolbar)` 常驻工具栏，⌘F 聚焦。
/// 播放器以覆盖层呈现（v1.0 全窗口播放页），不塞进详情栏。
public struct AppShellView: View {
    /// 导航模型（由 ``RootShell`` 注入并共享给菜单命令）。
    @Bindable private var model: NavigationModel

    /// 当前会话；`nil` 表示未登录（页面降级为占位）。
    private let session: PrismSession?

    /// 播放编排器（协商 → 引擎 → 进度上报 → UI）。
    @State private var playback = PlaybackCoordinator()

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
        HStack(spacing: 0) {
            if model.isSidebarVisible {
                sidebarColumn
            }

            ContentColumnView(model: model, session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.surface)
        }
        .frame(minWidth: 960, minHeight: 600)
        .navigationTitle(model.windowTitle)
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
        // 登录后立刻预取媒体库列表。
        //
        // 侧边栏的「电影 / 剧集」用的是占位 id，真实 view id 只有 `/Views` 返回后
        // 才知道。之前只有首页加载成功才回填，于是「登录 → 立刻按 ⌘2」会用
        // `ParentId=library.movies` 查库，得到空库或错误页。这里在进入外壳时
        // 就取一次，不依赖用户先去首页。
        .task {
            await prefetchLibraries()
        }
        .animation(playerAnimation, value: model.isPlayerPresented)
        // 关闭播放器有三条路径：播放器内的返回按钮、Esc、⌘[。
        // 后两条只改 `isPlayerPresented`，不会走 `PlayerHost` 的返回回调，
        // 因此必须在这里兜底停止引擎——否则画面消失，解码器与进度上报仍在跑。
        .onChange(of: model.isPlayerPresented) { _, isPresented in
            guard !isPresented else { return }
            Task { await playback.stop() }
        }
    }

    /// 侧栏和分隔线共用一个裁剪边界，让靠内容区的上下角保持圆弧。
    private var sidebarColumn: some View {
        HStack(spacing: 0) {
            SidebarView(model: model)
                .frame(width: SidebarView.columnWidth)
                .frame(maxHeight: .infinity)
            Divider()
        }
        .frame(width: SidebarView.columnWidth + 1)
        .frame(maxHeight: .infinity)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: Radius.panel,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: Radius.panel,
                topTrailingRadius: Radius.panel,
                style: .continuous
            )
        )
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: 媒体库预取

    /// 预取 `/Users/{id}/Views` 并把真实 view id 注入导航模型。
    ///
    /// 失败静默：这只是提前量，首页自己的加载会再取一次。
    private func prefetchLibraries() async {
        guard let session, model.libraryRoutes.isEmpty else { return }

        // 演示模式走内置数据源：它的 `client` 指向假地址，发真实请求必然失败。
        let source: any HomeDataSource = session.isDemo
            ? DemoDataSources.Home()
            : session.homeDataSource
        guard let views = try? await source.views() else { return }
        for view in views {
            model.registerLibraryRoute(
                .library(id: view.id, type: LibraryKind(collectionType: view.collectionType)),
                name: view.name
            )
        }
    }

    // MARK: 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                model.toggleSidebar()
            } label: {
                Image(systemName: model.isSidebarVisible ? "sidebar.left" : "sidebar.right")
            }
            .help(model.isSidebarVisible ? "隐藏边栏" : "显示边栏")
            .accessibilityLabel(model.isSidebarVisible ? "隐藏边栏" : "显示边栏")
        }

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

    }

    // MARK: 播放器覆盖层

    @ViewBuilder
    private var playerOverlay: some View {
        if model.isPlayerPresented, let route = model.playerRoute {
            PlayerHost(
                route: route,
                session: session,
                coordinator: playback,
                onDismiss: { model.dismissPlayer() }
            )
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
/// 首页保持挂载以保留数据与滚动位置；其他根页面按路由切换。
private struct ContentColumnView: View {
    /// 导航模型。
    @Bindable var model: NavigationModel

    /// 当前会话；`nil` 时各页面降级为占位。
    let session: PrismSession?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let showsHome = model.rootContentRoute == .home

        ZStack {
            homeContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(showsHome ? 1 : 0)
                .allowsHitTesting(showsHome)
                .accessibilityHidden(!showsHome)

            if !showsHome {
                routedContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(model.rootContentRoute)
                    .transition(.opacity)
            }

            if let itemID = model.selectedDetailItemID {
                DetailContentView(model: model, session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.surface)
                    .id(itemID)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .offset(x: 24)),
                            removal: .opacity.combined(with: .offset(x: -12))
                        )
                    )
                    .zIndex(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: Motion.standard),
            value: model.rootContentRoute
        )
        .animation(
            reduceMotion ? nil : .easeInOut(duration: Motion.slow),
            value: model.selectedDetailItemID
        )
    }

    @ViewBuilder
    private var homeContent: some View {
        if let session {
            HomeView(
                model: HomeViewModel(
                    dataSource: session.isDemo
                        ? DemoDataSources.Home()
                        : session.homeDataSource
                ),
                // 不传 accessToken：图片走 `EmbyImageLoader` 的鉴权头，令牌不进 URL。
                imageResolver: HomeImageResolver(
                    baseURL: session.server.baseURL,
                    accessToken: nil
                ),
                onNavigate: { route in model.navigate(to: route) },
                onLibrariesLoaded: { libraries in
                    // 将服务端真实 view id 注入侧边栏，避免用占位 id 发起请求。
                    for library in libraries {
                        model.registerLibraryRoute(
                            .library(
                                id: library.id,
                                type: LibraryKind(collectionType: library.collectionType)
                            ),
                            name: library.name
                        )
                    }
                },
                isActive: model.rootContentRoute == .home
            )
        } else {
            HomePlaceholderView()
        }
    }

    @ViewBuilder
    private var routedContent: some View {
        switch model.rootContentRoute {
        case .home:
            EmptyView()
        case let .library(id, type):
            if let session {
                LibraryView(
                    viewModel: LibraryViewModel(
                        dataSource: session.isDemo
                            ? DemoDataSources.Library()
                            : session.libraryDataSource,
                        libraryId: id,
                        // `MediaKind` 是 Emby 的媒体大类（Video/Audio/Photo/Book），
                        // 不是「电影/剧集」。具体类型由 `LibraryKind.itemTypes` 决定，
                        // 它来自服务端 `CollectionType`，不是按库名猜的。
                        kind: type.mediaKind,
                        includeItemTypes: type.itemTypes
                    ),
                    libraryName: model.libraryTitle(for: model.rootContentRoute),
                    countUnit: type.countUnit,
                    selectedItemID: model.selectedDetailItemID,
                    onOpenDetail: { item in model.navigate(to: .detail(itemId: item.id)) },
                    onPlay: { item in
                        model.navigate(to: .player(
                            itemId: item.id,
                            mediaSourceId: item.mediaSources.first?.id,
                            resumeAt: Self.resumePoint(for: item)
                        ))
                    }
                )
                // 换库必须换一个 VM：`@State` 会保留上一个库的分页、排序与筛选。
                .id(id)
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
                        // 人物 / 合集等非可播条目不该进电影详情页：
                        // 那里会给一个能点、但必然失败的播放按钮。
                        guard result.kind == .movie || result.kind == .series || result.kind == .episode
                        else { return }
                        model.navigate(to: .detail(itemId: result.id))
                    },
                    onPlay: { result in
                        model.navigate(to: .player(
                            itemId: result.id,
                            mediaSourceId: result.mediaItem?.mediaSources.first?.id,
                            resumeAt: result.resumePosition
                        ))
                    }
                )
            } else {
                SearchPlaceholderView()
            }
        case .downloads:
            DownloadsPlaceholderView()
        case .settings:
            SettingsView(
                selection: $model.settingsTab,
                server: session?.server,
                isDemo: session?.isDemo ?? false,
                onSwitchServer: { model.isServerSwitcherPresented = true }
            )
        case .detail:
            Color.clear
        case .player:
            // 播放器是覆盖层，内容栏保持原页面。
            Color.clear
        }
    }

    /// 播放起点：已看完的从头播，未看完的接着上次。
    ///
    /// 媒体库网格与右键菜单都走这一个入口，所以「播放」和「从上次位置继续」
    /// 不再等价——后者本来就是这个行为。
    ///
    /// - Parameter item: 被播放的条目。
    /// - Returns: 起播位置。
    static func resumePoint(for item: MediaItem) -> Ticks {
        item.userData.played ? .zero : item.userData.playbackPosition
    }
}

// MARK: - 全宽详情页

/// 在主内容栏中展示当前条目的详情，点击节目后占满内容区域。
private struct DetailContentView: View {
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
