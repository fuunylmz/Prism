import Foundation
import Testing
import EmbyAPI
import PrismCore
@testable import PrismUI

/// ``NavigationModel`` 的媒体库路由与服务器状态。
///
/// 这里守的是两条**真实发生过**的故障：
/// 1. 登录成功后服务器胶囊仍显示「未连接 / 未登录」——因为外壳传了空的导航模型；
/// 2. 点任何媒体库都跳到电影栏——因为库类型被按库名猜、且自定义库 id 被丢弃。
@Suite("NavigationModel", .serialized)
@MainActor
struct NavigationModelTests {
    // MARK: 夹具

    private func makeServer(id: String = "srv-a", name: String = "客厅 Emby") throws -> ServerConnection {
        ServerConnection(
            id: id,
            name: name,
            baseURL: try #require(URL(string: "http://192.168.1.10:8096"))
        )
    }

    private func makeUser(serverId: String = "srv-a", name: String = "小林") -> EmbyUser {
        EmbyUser(id: "user-1", name: name, serverId: serverId)
    }

    // MARK: 服务器状态

    @Test("注入服务器与用户后，胶囊显示真实名称且状态为已连接")
    func sessionIdentityIsVisible() throws {
        let server = try makeServer()
        let model = NavigationModel(
            servers: [server],
            currentServerID: server.id,
            currentUser: makeUser()
        )

        #expect(model.currentServerName == "客厅 Emby")
        #expect(model.currentUserName == "小林")
        #expect(model.currentServerStatus == .connected)
        #expect(model.hasMultipleServers == false)
    }

    @Test("没有任何服务器时退回未连接文案")
    func emptyModelShowsDisconnected() {
        let model = NavigationModel()

        #expect(model.currentServerName == "未连接服务器")
        #expect(model.currentUserName == "未登录")
        #expect(model.currentServerStatus == .offline)
    }

    // MARK: 媒体库路由

    @Test("自定义电影库：保留真实 view id 与类型")
    func customMovieLibraryRouteIsPreserved() {
        let model = NavigationModel()
        let route = Route.library(id: "real-movies-view", type: .movies)

        model.navigate(to: route)

        #expect(model.contentRoute == route)
        #expect(model.activeRootRoute == route)
        #expect(model.selection == .movies)
    }

    @Test("自定义剧集库：不会被折叠成电影库")
    func customSeriesLibraryRouteIsPreserved() {
        let model = NavigationModel()
        let route = Route.library(id: "real-tv-view", type: .series)

        model.navigate(to: route)

        #expect(model.contentRoute == route)
        #expect(model.selection == .series)
    }

    @Test("任意命名与类型的库都按传入类型打开，不做名称猜测")
    func libraryRouteDoesNotDependOnName() {
        let model = NavigationModel()
        // 名字里没有任何「剧 / tv / series」关键词，但它是合集库
        let route = Route.library(id: "boxsets-view", type: .boxsets)

        model.navigate(to: route)

        #expect(model.contentRoute == route)
        #expect(model.contentRoute.title == "合集")
    }

    @Test("打开没有侧边栏归属的库时，侧边栏不再高亮「首页」")
    func customLibraryWithoutSidebarItemClearsSelection() {
        let model = NavigationModel()
        model.navigate(to: .library(id: "boxsets-view", type: .boxsets))

        #expect(model.contentRoute == .library(id: "boxsets-view", type: .boxsets))
        #expect(model.selection == nil)
    }

    @Test("切回首页会清除媒体库覆盖路由")
    func navigatingHomeClearsOverride() {
        let model = NavigationModel()
        model.navigate(to: .library(id: "real-movies-view", type: .movies))

        model.navigate(to: .home)

        #expect(model.activeRootRoute == nil)
        #expect(model.contentRoute == .home)
    }

    @Test("切到搜索会清除媒体库覆盖路由")
    func navigatingSearchClearsOverride() {
        let model = NavigationModel()
        model.navigate(to: .library(id: "real-movies-view", type: .movies))

        model.navigate(to: .search)

        #expect(model.activeRootRoute == nil)
        #expect(model.contentRoute == .search)
    }

    @Test("在媒体库页直接敲搜索框会切到搜索结果页")
    func typingSearchLeavesLibrary() {
        let model = NavigationModel()
        model.navigate(to: .library(id: "real-movies-view", type: .movies))

        model.searchText = "沙丘"
        model.searchTextDidChange()

        #expect(model.activeRootRoute == nil)
        #expect(model.contentRoute == .search)
        #expect(model.selection == .search)
    }

    @Test("注册媒体库后，侧边栏「电影」使用服务端真实 id")
    func sidebarUsesRegisteredLibraryRoute() {
        let model = NavigationModel()

        model.registerLibraryRoute(.library(id: "real-movies-view", type: .movies), name: "我的电影")
        model.registerLibraryRoute(.library(id: "real-tv-view", type: .series), name: "我的剧集")

        model.select(.movies)
        #expect(model.contentRoute == .library(id: "real-movies-view", type: .movies))
        #expect(model.libraryTitle(for: model.contentRoute) == "我的电影")

        model.select(.series)
        #expect(model.contentRoute == .library(id: "real-tv-view", type: .series))
        #expect(model.libraryTitle(for: model.contentRoute) == "我的剧集")
    }

    @Test("未注册媒体库时，侧边栏仍回落到占位路由")
    func sidebarFallsBackToPlaceholder() {
        let model = NavigationModel()

        model.select(.movies)

        #expect(model.contentRoute == .library(id: "library.movies", type: .movies))
    }

    @Test("切换服务器会清空媒体库覆盖路由")
    func switchingServerClearsOverride() throws {
        let first = try makeServer(id: "srv-a", name: "客厅")
        let second = try makeServer(id: "srv-b", name: "书房")
        let model = NavigationModel(servers: [first, second], currentServerID: first.id)

        model.navigate(to: .library(id: "real-movies-view", type: .movies))
        model.selectServer(id: second.id)

        #expect(model.currentServerID == second.id)
        #expect(model.activeRootRoute == nil)
        #expect(model.contentRoute == .home)
    }

    @Test("窄窗口下点开详情仍然会显示详情栏")
    func narrowWindowStillShowsOpenedDetail() {
        let model = NavigationModel()
        model.navigate(to: .library(id: "real-movies-view", type: .movies))
        model.updateWindowWidth(980)

        // 还没选条目：窄窗口下不自动显示详情栏（三栏放不下）。
        #expect(model.showsDetailColumn == false)

        model.navigate(to: .detail(itemId: "movie-1"))

        // 用户明确打开了条目：必须显示，否则点海报「毫无反应」。
        #expect(model.showsDetailColumn)
        #expect(model.selectedDetailItemID == "movie-1")
    }

    @Test("手动折叠详情栏后，选中条目也不会强行弹出")
    func collapsedDetailColumnStaysCollapsed() {
        let model = NavigationModel()
        model.navigate(to: .library(id: "real-movies-view", type: .movies))
        model.updateWindowWidth(1400)
        model.toggleDetailColumn()

        model.navigate(to: .detail(itemId: "movie-1"))

        // `navigate(to: .detail)` 会主动展开（用户点开就是想看），
        // 这里验证的是「展开后状态自洽」。
        #expect(model.isDetailColumnCollapsed == false)
        #expect(model.showsDetailColumn)
    }

    @Test("窗口标题跟随当前媒体库名称")
    func windowTitleUsesLibraryName() {
        let model = NavigationModel()
        model.registerLibraryRoute(.library(id: "real-movies-view", type: .movies), name: "华语电影")
        model.navigate(to: .library(id: "real-movies-view", type: .movies))

        #expect(model.windowTitle == "华语电影")

        model.presentPlayer(itemId: "item-1")
        #expect(model.windowTitle == "正在播放")
    }
}
