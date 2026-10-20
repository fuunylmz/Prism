import SwiftUI

// MARK: - 导航类快捷键

/// 导航与窗口类快捷键的唯一事实来源。
///
/// 取值严格来自 `docs/research/ux-benchmark.md` §4.4「键盘快捷键（全局层）」，
/// 并遵守 §4.6.5 的优先级规则：
/// - HIG 保护区（⌘F / ⌘, / ⌘W / ⌘Q 等）保持标准语义，不重定义；
/// - **播放器快捷键（空格、←/→、F、M、S、A 等）不属于本文件**，由播放器工单实现；
/// - `Esc` 的「返回」语义通过 `onExitCommand` 交给 responder chain，
///   不注册成菜单快捷键，避免在文本输入、sheet、popover 中吞掉取消操作；
/// - `↑` / `↓` 的列表选择由 `List(selection:)` 原生提供，不额外绑定。
///
/// 菜单命令（``PrismCommands``）与侧边栏提示都从这里取键位，保证「菜单里能看到的
/// 快捷键 = 实际生效的快捷键」（HIG 要求）。
public enum NavigationShortcuts {
    /// ⌘1：首页。
    public static let home = KeyboardShortcut("1", modifiers: .command)
    /// ⌘2：电影。
    public static let movies = KeyboardShortcut("2", modifiers: .command)
    /// ⌘3：剧集。
    public static let series = KeyboardShortcut("3", modifiers: .command)
    /// ⌘F：聚焦工具栏搜索框（HIG 的 Find）。
    public static let search = KeyboardShortcut("f", modifiers: .command)
    /// ⌘,：设置。
    public static let settings = KeyboardShortcut(",", modifiers: .command)
    /// ⌘⇧S：服务器切换。
    public static let serverSwitcher = KeyboardShortcut("s", modifiers: [.command, .shift])
    /// ⌘⇧D：下载管理（v1.1；v1.0 菜单项为禁用态）。
    public static let downloads = KeyboardShortcut("d", modifiers: [.command, .shift])
    /// ⌘[：返回。
    public static let goBack = KeyboardShortcut("[", modifiers: .command)
    /// ⌃⌘S：显示 / 隐藏边栏。
    public static let toggleSidebar = KeyboardShortcut("s", modifiers: [.control, .command])
}

// MARK: - 侧边栏提示

extension SidebarItem {
    /// 该导航项的快捷键；无快捷键时为 `nil`。
    public var shortcut: KeyboardShortcut? {
        switch self {
        case .home: NavigationShortcuts.home
        case .movies: NavigationShortcuts.movies
        case .series: NavigationShortcuts.series
        case .search: NavigationShortcuts.search
        case .downloads: NavigationShortcuts.downloads
        case .settings: NavigationShortcuts.settings
        }
    }

    /// 快捷键的展示文案（用于侧边栏行尾与 `.help` 提示）。
    public var shortcutHint: String? {
        switch self {
        case .home: "⌘1"
        case .movies: "⌘2"
        case .series: "⌘3"
        case .search: "⌘F"
        case .downloads: "⌘⇧D"
        case .settings: "⌘,"
        }
    }
}
