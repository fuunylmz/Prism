import SwiftUI

// MARK: - 根外壳

/// Prism 的根视图：创建导航模型、挂载主题、把模型暴露给菜单命令。
///
/// 这是 `Sources/PrismUI/RootView.swift` 唯一需要调用的入口：
///
/// ```swift
/// public var body: some View {
///     RootShell()
/// }
/// ```
///
/// 如果 App 需要自己持有模型（例如把当前服务器注入进去），使用第二个初始化器：
///
/// ```swift
/// @State private var navigation = NavigationModel(servers: [server], currentUser: user)
/// // ...
/// RootShell(model: navigation)
/// ```
///
/// 主题通过 `DesignSystem` 的 ``SwiftUI/View/prismTheme(_:)`` 挂载一次；
/// 默认跟随系统外观，v1.0 如需「影院暗色」由上层传 `PrismTheme(appearance: .dark)`。
public struct RootShell: View {
    @State private var model: NavigationModel
    private let theme: PrismTheme

    /// 使用全新的导航模型与默认主题。
    public init() {
        _model = State(initialValue: NavigationModel())
        self.theme = .default
    }

    /// 使用外部注入的导航模型。
    ///
    /// - Parameters:
    ///   - model: 与菜单命令、上层数据共享的导航模型。
    ///   - theme: 主题配置，默认跟随系统。
    public init(model: NavigationModel, theme: PrismTheme = .default) {
        _model = State(initialValue: model)
        self.theme = theme
    }

    public var body: some View {
        AppShellView(model: model)
            .prismTheme(theme)
            .focusedSceneValue(\.navigationModel, model)
    }
}
