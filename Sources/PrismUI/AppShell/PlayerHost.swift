import SwiftUI
import PrismCore
import PrismPlayback

// MARK: - 播放器宿主

/// 播放器覆盖层的宿主：负责「进页面就开始播放」以及生命周期清理。
///
/// 拆出来是为了让 `AppShellView` 保持可读——播放器有自己的 `.task` 启动、
/// 停止时的资源清理，塞在外壳的 `body` 里会让那个函数过长。
struct PlayerHost: View {
    let route: Route
    let session: PrismSession?
    let coordinator: PlaybackCoordinator
    let onDismiss: () -> Void

    var body: some View {
        Group {
            if case let .player(itemId, _, resumeAt) = route, session != nil {
                PlayerView(
                    model: coordinator.playerModel,
                    title: coordinator.title.isEmpty ? "正在播放" : coordinator.title,
                    subtitle: coordinator.subtitle,
                    onBack: {
                        Task { await coordinator.stop() }
                        onDismiss()
                    }
                )
                .task(id: itemId) {
                    guard let session else { return }
                    await coordinator.play(itemId: itemId, resumeAt: resumeAt, session: session)
                }
            } else {
                // 没有会话（未登录）时不该走到这里；给一个可退出的空态而不是黑屏。
                VStack(spacing: Spacing.lg) {
                    Image(systemName: "play.slash")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(Palette.textSecondary)
                    Text("无法播放")
                        .font(Typography.title)
                    Text("请先连接服务器并登录。")
                        .font(Typography.body)
                        .foregroundStyle(Palette.textSecondary)
                    PrismSecondaryButton("返回") { onDismiss() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.surface)
            }
        }
    }
}
