import SwiftUI
import PrismCore
import EmbyAPI
import PrismData
import PrismPlayback

/// Prism 的根视图。
///
/// 三条路径：
/// 1. **演示模式**（`-DemoMode YES` / `PRISM_DEMO=1`）—— 不联网，用内置媒体库；
/// 2. **已登录** —— 从本机存储恢复会话，进主界面；
/// 3. **未登录** —— 显示连接与登录页。
public struct RootView: View {
    /// 启动引导：决定上面三条路径中的哪一条。
    @State private var bootstrapper = SessionBootstrapper()

    /// 演示模式下的会话（真实模式下恒为 `nil`）。
    @State private var demoSession: PrismSession?

    /// 演示会话是否还在准备。
    @State private var isPreparingDemo = false

    public init() {}

    public var body: some View {
        Group {
            if let demoSession {
                RootShell(model: navigationModel(for: demoSession), session: demoSession)
                    .id(demoSession.session.id)
            } else if DemoMode.isEnabled {
                preparingView
                    .task {
                        guard !isPreparingDemo, demoSession == nil else { return }
                        isPreparingDemo = true
                        await prepareDemoSession()
                        isPreparingDemo = false
                    }
            } else {
                liveContent
            }
        }
        .task {
            // 演示模式不需要读本机存储。
            guard !DemoMode.isEnabled else { return }
            await bootstrapper.restore()
        }
    }

    // MARK: 真实模式

    @ViewBuilder
    private var liveContent: some View {
        switch bootstrapper.phase {
        case .restoring:
            preparingView
        case .needsConnection:
            ConnectView { server, auth, persist in
                await bootstrapper.signedIn(server: server, auth: auth, persist: persist)
            }
        case let .ready(session):
            RootShell(
                model: navigationModel(for: session, signOut: { bootstrapper.requestSignOut() }),
                session: session
            )
            // 换账号 / 换服务器时强制重建外壳，否则 `@State` 会保留旧模型。
            .id(session.session.id)
        }
    }

    private var preparingView: some View {
        VStack(spacing: Spacing.lg) {
            ProgressView()
                .controlSize(.large)
            Text("正在准备…")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
        }
        .frame(minWidth: 960, minHeight: 600)
        .background(Palette.surface)
    }

    // MARK: 导航

    /// 为当前会话建立带有服务器、用户和连接状态的导航模型。
    ///
    /// 服务器胶囊读取的是 `NavigationModel`，不能传一个默认空模型，否则主页面
    /// 虽然已经拿到有效会话，底部仍会显示「未连接 / 未登录」。
    /// - Parameter signOut: 侧边栏 / 菜单里「退出登录」要执行的动作。
    ///   不接线时 `NavigationModel.requestSignOut()` 是空操作，用户点了没有任何反应。
    @MainActor
    private func navigationModel(
        for session: PrismSession,
        signOut: (@MainActor () -> Void)? = nil
    ) -> NavigationModel {
        let model = NavigationModel(
            servers: [session.server],
            currentServerID: session.server.id,
            currentUser: session.user
        )
        model.serverStates[session.server.id] = .connected
        if let signOut {
            model.onSignOut = signOut
        }
        return model
    }

    // MARK: 演示模式

    /// 建立演示会话。
    ///
    /// 失败时静默退回未登录态（不弹错误框）——演示模式本身是可选路径，
    /// 失败不应该阻断 App 启动。
    private func prepareDemoSession() async {
        guard let session = try? await DemoDataSources.makeSession() else { return }
        let prismSession = PrismSession(server: DemoDataSources.server, session: session)
        await prismSession.activate()
        demoSession = prismSession
    }
}

