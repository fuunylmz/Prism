import SwiftUI
import PrismCore
import EmbyAPI
import PrismData
import PrismPlayback

/// Prism 的根视图。
///
/// 三条路径：
/// 1. **演示模式**（`-DemoMode YES` / `PRISM_DEMO=1`）—— 不联网，用内置媒体库；
/// 2. **已登录** —— 从 Keychain 恢复会话，进主界面；
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
                RootShell(model: NavigationModel(), session: demoSession)
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
            // 演示模式不需要碰 Keychain。
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
            RootShell(model: NavigationModel(), session: session)
                .environment(\.signOutHandler, { await bootstrapper.signOut() })
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

// MARK: - 登出入口

/// 登出回调的 Environment key。
///
/// 用 Environment 而不是逐层传参：侧边栏的「退出登录」在很深的位置，
/// 一层层传会让每个中间视图都被迫认识会话管理。
private struct SignOutHandlerKey: EnvironmentKey {
    static let defaultValue: (@MainActor () async -> Void)? = nil
}

public extension EnvironmentValues {
    /// 登出动作；`nil` 表示当前不可登出（例如演示模式）。
    var signOutHandler: (@MainActor () async -> Void)? {
        get { self[SignOutHandlerKey.self] }
        set { self[SignOutHandlerKey.self] = newValue }
    }
}
