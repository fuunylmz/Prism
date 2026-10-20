import SwiftUI
import PrismCore
import EmbyAPI
import PrismData
import PrismPlayback

/// Prism 的根视图。
///
/// 负责两件事：
/// 1. 判断是否进入**演示模式**（`-DemoMode YES` 或 `PRISM_DEMO=1`）；
/// 2. 把对应的会话交给 `RootShell`。
///
/// 演示模式让 App 在没有 Emby 服务器的情况下也能完整浏览界面：
/// 首页、媒体库、详情、搜索、播放全部可用，数据来自 ``DemoEmbyClient``。
/// 这不是「假数据兜底」，而是刻意设计的一等公民——它让 UI 开发与后端解耦。
public struct RootView: View {
    /// 演示模式下的会话（真实模式下恒为 `nil`）。
    @State private var demoSession: PrismSession?

    public init() {}

    public var body: some View {
        Group {
            if let demoSession {
                RootShell(model: NavigationModel(), session: demoSession)
            } else if DemoMode.isEnabled {
                // 演示会话正在建立：先显示骨架，避免闪一下空界面。
                ProgressView("正在准备演示数据…")
                    .frame(minWidth: 960, minHeight: 600)
                    .task { await prepareDemoSession() }
            } else {
                // 真实模式：尚无登录流程，先给外壳（未登录态显示占位）。
                RootShell(model: NavigationModel())
            }
        }
    }

    /// 建立演示会话。
    ///
    /// 失败时静默退回未登录态（不弹错误框）——演示模式本身是可选路径，
    /// 失败不应该阻断 App 启动。
    private func prepareDemoSession() async {
        guard let session = try? await DemoDataSources.makeSession() else { return }
        let server = DemoDataSources.server
        let prismSession = PrismSession(server: server, session: session)
        await prismSession.activate()
        demoSession = prismSession
    }
}
