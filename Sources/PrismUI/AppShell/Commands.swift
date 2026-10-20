import SwiftUI

// MARK: - 焦点值

/// 把当前窗口的 ``NavigationModel`` 暴露给菜单命令。
///
/// `Commands` 拿不到视图的 `@State`，因此用 `focusedSceneValue` 把模型挂到场景上；
/// ``RootShell`` 负责写入，``PrismCommands`` 通过 `@FocusedValue` 读取。
public struct NavigationModelFocusedKey: FocusedValueKey {
    /// 焦点值类型。
    public typealias Value = NavigationModel
}

public extension FocusedValues {
    /// 当前场景的导航模型；窗口未就绪时为 `nil`。
    var navigationModel: NavigationModel? {
        get { self[NavigationModelFocusedKey.self] }
        set { self[NavigationModelFocusedKey.self] = newValue }
    }
}

// MARK: - 菜单命令

/// Prism 的菜单栏命令（导航 / 窗口 / 服务器）。
///
/// 接入方式（由 `App/PrismApp.swift` 的 owner 完成）：
///
/// ```swift
/// WindowGroup { RootView() }
///     .commands { PrismCommands() }
/// ```
///
/// 命令通过 `@FocusedValue(\.navigationModel)` 自动绑定到当前窗口的
/// ``NavigationModel``，因此不需要在 App 里持有模型；没有活动窗口时所有命令禁用。
///
/// **范围**：只实现导航类命令。播放器命令（播放/暂停、字幕、音轨、速度、全屏等）
/// 属于播放器工单，不在此处定义，避免与 `§4.6` 的 37 条映射表产生两套实现。
public struct PrismCommands: Commands {
    @FocusedValue(\.navigationModel) private var focusedModel

    /// 显式注入的模型（预览 / 测试用）。正常接入时保持 `nil`，走焦点值。
    private let explicitModel: NavigationModel?

    /// 使用当前窗口的焦点模型（推荐）。
    public init() {
        self.explicitModel = nil
    }

    /// 显式注入模型（用于预览或无法使用焦点值的场景）。
    ///
    /// - Parameter model: 与窗口共享的导航模型。
    public init(model: NavigationModel) {
        self.explicitModel = model
    }

    /// 当前生效的导航模型。
    private var model: NavigationModel? {
        explicitModel ?? focusedModel
    }

    public var body: some Commands {
        // App 菜单：设置…（⌘,）。替换系统默认项，避免出现两个「设置」。
        CommandGroup(replacing: .appSettings) {
            Button("设置…") {
                guard let model else { return }
                model.openSettings(model.settingsTab)
            }
            .keyboardShortcut(NavigationShortcuts.settings)
            .disabled(model == nil)
        }

        // 文件菜单：服务器切换与退出登录。
        CommandGroup(after: .newItem) {
            Divider()
            Button("切换服务器…") {
                model?.isServerSwitcherPresented = true
            }
            .keyboardShortcut(NavigationShortcuts.serverSwitcher)
            .disabled(model == nil || (model?.servers.isEmpty ?? true))

            Button("添加服务器…") {
                // v1.0 的添加流程由连接向导工单接入；外壳只保留菜单位。
            }
            .disabled(true)
            .help("添加服务器流程由连接向导接入后启用")

            Button("退出登录") {
                model?.requestSignOut()
            }
            .disabled(model?.currentUser == nil)
        }

        // 显示菜单：一级导航（与侧边栏一一对应）。
        CommandGroup(before: .sidebar) {
            Button("首页") { model?.select(.home) }
                .keyboardShortcut(NavigationShortcuts.home)
                .disabled(model == nil)

            Button("电影") { model?.select(.movies) }
                .keyboardShortcut(NavigationShortcuts.movies)
                .disabled(model == nil)

            Button("剧集") { model?.select(.series) }
                .keyboardShortcut(NavigationShortcuts.series)
                .disabled(model == nil)

            Button("搜索") {
                guard let model else { return }
                model.select(.search)
            }
            .keyboardShortcut(NavigationShortcuts.search)
            .disabled(model == nil)
        }

        // 显示菜单：返回、边栏与详情栏。
        CommandGroup(after: .sidebar) {
            Divider()
            Button("返回") { model?.goBack() }
                .keyboardShortcut(NavigationShortcuts.goBack)
                .disabled(model?.canGoBack != true)

            Button(model?.isSidebarVisible == false ? "显示边栏" : "隐藏边栏") {
                model?.toggleSidebar()
            }
            .keyboardShortcut(NavigationShortcuts.toggleSidebar)
            .disabled(model == nil)

            Button(model?.isDetailColumnCollapsed == true ? "显示详情栏" : "隐藏详情栏") {
                model?.toggleDetailColumn()
            }
            .disabled(model?.canToggleDetailColumn != true)
        }
    }
}
