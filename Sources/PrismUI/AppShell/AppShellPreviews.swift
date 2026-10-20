import PrismCore
import SwiftUI

// MARK: - 预览数据

/// 外壳预览用的示例服务器与用户（不联网）。
private enum ShellPreviewData {
    /// 示例服务器。
    static let server = ServerConnection(
        id: PreviewData.serverId,
        name: "客厅 Emby",
        baseURL: URL(filePath: "/"),
        lastConnectedAt: nil
    )

    /// 第二台服务器（用于演示胶囊的切换箭头）。
    static let secondServer = ServerConnection(
        id: "preview-server-2",
        name: "卧室 Emby",
        baseURL: URL(filePath: "/"),
        lastConnectedAt: nil
    )

    /// 示例用户。
    static let user = EmbyUser(
        id: "preview-user",
        name: "小林",
        serverId: PreviewData.serverId,
        isAdministrator: true
    )

    /// 造一个带服务器与用户的导航模型。
    ///
    /// - Parameters:
    ///   - selection: 初始选中项。
    ///   - multipleServers: 是否放两台服务器。
    /// - Returns: 导航模型。
    @MainActor
    static func model(selection: SidebarItem, multipleServers: Bool = false) -> NavigationModel {
        NavigationModel(
            selection: selection,
            servers: multipleServers ? [server, secondServer] : [server],
            currentUser: user
        )
    }
}

// MARK: - 预览

#Preview("外壳 · 首页（暗色）") {
    RootShell(
        model: ShellPreviewData.model(selection: .home),
        theme: PrismTheme(appearance: .dark)
    )
    .frame(width: 1280, height: 800)
}

#Preview("外壳 · 媒体库（浅色）") {
    RootShell(
        model: ShellPreviewData.model(selection: .movies),
        theme: PrismTheme(appearance: .light)
    )
    .frame(width: 1280, height: 800)
}

#Preview("外壳 · 媒体库 + 详情") {
    let model = ShellPreviewData.model(selection: .series)
    model.navigate(to: .detail(itemId: "preview-series-1"))
    return RootShell(model: model)
        .frame(width: 1280, height: 800)
}

#Preview("外壳 · 搜索") {
    let model = ShellPreviewData.model(selection: .search)
    model.searchText = "科幻"
    return RootShell(model: model)
        .frame(width: 1280, height: 800)
}

#Preview("外壳 · 播放器覆盖层") {
    let model = ShellPreviewData.model(selection: .movies)
    model.presentPlayer(itemId: "preview-movie-1", resumeAt: Ticks(seconds: 754))
    return RootShell(model: model)
        .frame(width: 1280, height: 800)
}

#Preview("外壳 · 多服务器") {
    RootShell(
        model: ShellPreviewData.model(selection: .home, multipleServers: true)
    )
    .frame(width: 1280, height: 800)
}

#Preview("外壳 · 窄窗口（详情栏自动收起）") {
    let model = ShellPreviewData.model(selection: .movies)
    model.updateWindowWidth(980)
    return RootShell(model: model)
        .frame(width: 980, height: 640)
}
