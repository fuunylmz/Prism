import PrismCore
import SwiftUI

// MARK: - 统一空态

/// 外壳占位页的统一容器。
///
/// 视觉直接复用 `DesignSystem` 的 ``EmptyStateView``（图标 + 标题 + 说明 + 可选主操作），
/// 只在下方追加一行可选脚注，用于标注「该页由哪个工单接入」以及 id 等排障信息。
///
/// 这样占位页与将来的真实空态共用同一套设计语言，接入真实页面时只需替换内容，
/// 不会出现「占位一种风格、正式另一种风格」的割裂。
struct ShellEmptyState: View {
    /// 顶部 SF Symbol。
    let systemImage: String
    /// 主标题。
    let title: LocalizedStringKey
    /// 一句解释（发生了什么 / 下一步做什么）。
    let message: LocalizedStringKey
    /// 可选脚注（快捷键提示、占位说明、id 等）。
    var footnote: String?

    var body: some View {
        VStack(spacing: Spacing.sm) {
            EmptyStateView(
                systemImage: systemImage,
                title: title,
                message: message
            )

            if let footnote {
                Text(footnote)
                    .font(Typography.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xl)
                    .accessibilityLabel("说明：\(footnote)")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 首页

/// 首页占位（S04）。真实内容：继续观看 / 接下来 / 最近添加。
///
/// - TODO: 由首页工单替换为真实视图（`HomeView` + `HomeViewModel`）。
struct HomePlaceholderView: View {
    var body: some View {
        ShellEmptyState(
            systemImage: "house",
            title: "首页",
            message: "继续观看、接下来与最近添加将在这里出现。",
            footnote: "首页工单接入后替换此占位"
        )
    }
}

// MARK: - 媒体库

/// 媒体库网格占位（S05）。
///
/// - TODO: 由媒体库工单替换为真实网格（`LibraryGridView` + `LibraryViewModel`）。
struct LibraryPlaceholderView: View {
    /// 服务端视图 id。
    let libraryID: String
    /// 库的内容形态。
    let type: LibraryKind

    var body: some View {
        ShellEmptyState(
            systemImage: type.systemImage,
            title: LocalizedStringKey(type.title),
            message: "媒体库网格将在这里显示，支持筛选、排序与无限滚动。",
            footnote: "库 id：\(libraryID) · 媒体库工单接入后替换此占位"
        )
    }
}

// MARK: - 搜索

/// 搜索落地页占位（S14）。
///
/// - TODO: 由搜索工单替换为「最近搜索 / 热门 / 结果分组」。
struct SearchPlaceholderView: View {
    var body: some View {
        ShellEmptyState(
            systemImage: "magnifyingglass",
            title: "搜索",
            message: "输入关键词查找影片、剧集与演员。",
            footnote: "搜索框在工具栏中，⌘F 可随时聚焦"
        )
    }
}

// MARK: - 下载

/// 下载管理占位（S17，v1.1）。
///
/// - TODO: v1.1 由下载工单实现；v1.0 侧边栏入口为禁用态。
struct DownloadsPlaceholderView: View {
    var body: some View {
        ShellEmptyState(
            systemImage: "arrow.down.circle",
            title: "下载",
            message: "下载管理将在 v1.1 提供，用于离线观看。",
            footnote: "v1.0 不包含离线下载"
        )
    }
}

// MARK: - 设置

/// 设置面板占位（S15）。
///
/// - TODO: 由设置工单替换为 5 个面板的真实表单（独立 `Settings` 窗口）。
struct SettingsPlaceholderView: View {
    /// 当前面板。
    let tab: SettingsTab

    var body: some View {
        ShellEmptyState(
            systemImage: tab.systemImage,
            title: "设置 · \(tab.title)",
            message: "该面板的设置项由设置工单接入。",
            footnote: "面板：\(tab.identifier)"
        )
    }
}

extension SettingsTab {
    /// 面板的稳定标识（用于占位说明与诊断，不参与持久化契约）。
    var identifier: String {
        switch self {
        case .playback: "playback"
        case .subtitles: "subtitles"
        case .network: "network"
        case .appearance: "appearance"
        case .servers: "servers"
        case .about: "about"
        }
    }
}

// MARK: - 详情

/// 详情栏占位（S07 / S08）。
///
/// - TODO: 由详情工单替换为 `ItemDetailView`（backdrop + 元数据 + 播放按钮）。
struct DetailPlaceholderView: View {
    /// 条目 id。
    let itemId: String

    var body: some View {
        ShellEmptyState(
            systemImage: "rectangle.on.rectangle",
            title: "条目详情",
            message: "海报、元数据、播放 / 收藏按钮与简介将在这里显示。",
            footnote: "条目 id：\(itemId) · 详情工单接入后替换此占位"
        )
    }
}

/// 详情栏空态：媒体库尚未选中任何条目时显示。
struct DetailEmptyView: View {
    var body: some View {
        ShellEmptyState(
            systemImage: "sidebar.right",
            title: "选择一部影片查看详情",
            message: "单击海报在右侧查看详情，双击直接播放。",
            footnote: "⌘[ 返回"
        )
    }
}

// MARK: - 播放器

/// 播放器覆盖层占位（S10）。
///
/// 只负责「全窗口覆盖 + 关闭」的壳；播放画面、控制条与**播放器快捷键**
/// （空格 / ←→ / F / M / S 等，见 ux-benchmark §4.6）由播放器工单实现，
/// 此处刻意不注册任何键盘映射，避免两套实现互相覆盖。
///
/// - TODO: 由播放器工单替换为 `PlayerView`（AetherEngine 渲染面 + 控制条）。
struct PlayerPlaceholderView: View {
    /// 播放器路由（携带条目 id 与续播点）。
    let route: Route?
    /// 关闭回调。
    let onClose: () -> Void

    private var title: String {
        guard case let .player(itemId, _, _) = route else { return "正在播放" }
        return "正在播放 · \(itemId)"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: Spacing.md) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.white.opacity(0.85))
                    .accessibilityHidden(true)

                Text("播放器占位")
                    .font(Typography.title)
                    .foregroundStyle(.white)

                Text("播放画面、控制条与播放器快捷键由播放器工单实现。")
                    .font(Typography.caption)
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
            }
            .padding(Spacing.xl)

            VStack {
                HStack(spacing: Spacing.sm) {
                    Text(title)
                        .font(Typography.headline)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)

                    Spacer(minLength: Spacing.sm)

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .help("关闭播放器（Esc）")
                    .accessibilityLabel("关闭播放器")
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.sm)
                .background(.black.opacity(0.35))

                Spacer()
            }
        }
        .accessibilityElement(children: .contain)
    }
}
