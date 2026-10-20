import SwiftUI
import PrismUI

/// Prism 的应用入口。
///
/// **保持极薄**：这里只负责 Scene 与菜单命令的装配，任何界面/状态/业务逻辑都必须放在
/// `Sources/PrismUI/` 中。这样 UI 团队可以独立演进，不必改动这个文件。
@main
struct PrismApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // 导航类快捷键（⌘1/⌘2/⌘3、⌘F、⌘,、⌘⇧S、Esc 返回）由 AppShell 提供；
            // 通过 focusedSceneValue 自动绑定到当前窗口的 NavigationModel。
            PrismCommands()
        }
    }
}
