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
/// 如果 App 需要自己持有模型（例如把当前服务器注入进去），使用带 `model` 的初始化器：
///
/// ```swift
/// @State private var navigation = NavigationModel(servers: [server], currentUser: user)
/// // ...
/// RootShell(model: navigation, session: session)
/// ```
///
/// 主题通过 `DesignSystem` 的 ``SwiftUI/View/prismTheme(_:)`` 挂载一次；
/// 默认跟随系统外观，v1.0 如需「影院暗色」由上层传 `PrismTheme(appearance: .dark)`。
public struct RootShell: View {
    @State private var model: NavigationModel
    private let theme: PrismTheme
    private let session: PrismSession?

    /// 使用全新的导航模型与默认主题（未登录态，各页面显示占位）。
    public init() {
        _model = State(initialValue: NavigationModel())
        self.theme = .default
        self.session = nil
    }

    /// 使用外部注入的导航模型与会话。
    ///
    /// - Parameters:
    ///   - model: 与菜单命令、上层数据共享的导航模型。
    ///   - theme: 主题配置，默认跟随系统。
    ///   - session: 已登录会话；传 `nil` 表示未登录，页面降级为占位。
    public init(model: NavigationModel, theme: PrismTheme = .default, session: PrismSession? = nil) {
        _model = State(initialValue: model)
        self.theme = theme
        self.session = session
    }

    public var body: some View {
        AppShellView(model: model, session: session)
            .prismTheme(theme)
            .posterImageLoader(imageLoader)
            .focusedSceneValue(\.navigationModel, model)
    }

    /// 海报加载器：演示模式用代码生成的渐变图，真实模式用带鉴权头的图片管线。
    ///
    /// 两者都实现 `PosterImageLoading`，页面代码不需要知道用的是哪一个。
    private var imageLoader: any PosterImageLoading {
        if session?.isDemo == true {
            return DemoImageLoader()
        }
        if let session {
            return session.imageLoader
        }
        return PlaceholderImageLoader()
    }
}
