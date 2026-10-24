import PrismCore
import SwiftUI

// MARK: - 设置主容器

/// 设置页主容器：左侧面板列表 + 右侧表单。
///
/// ## 形态
///
/// 与 macOS「系统设置」一致：**左侧列表 + 右侧表单**，不用 sheet、不用 `TabView`
/// 顶部分页（`docs/research/ux-benchmark.md` §S15）。这里用 `List` + `Divider` +
/// 内容区手写两栏，宽度与折叠完全可控。
///
/// ## 与路由的联动
///
/// 面板选中态有两种来源：
///
/// - 传 `selection:` 时由外部（`NavigationModel.settingsTab`）持有，⌘, / 侧边栏
///   切换面板后重进设置仍停在原面板；
/// - 不传时用内部 `@State`，适合预览或独立窗口。
///
/// ```swift
/// // AppShell 里的接入（一行）：
/// SettingsView(selection: $model.settingsTab, server: session?.server, isDemo: session?.isDemo ?? false)
/// ```
///
/// ## 即时生效
///
/// 所有设置项直接绑定 ``PrismCore/AppSettings``，没有「保存」按钮——`AppSettings`
/// 的每个属性在 `didSet` 里写 `UserDefaults`，因此改动立即持久化。
public struct SettingsView: View {
    /// 全局设置（`@Bindable` 让 SwiftUI 观察属性变化）。
    @Bindable private var settings: AppSettings

    /// 外部持有的面板选中态；`nil` 时用内部状态。
    private let externalSelection: Binding<SettingsTab>?

    /// 当前服务器；`nil` 表示未连接（网络面板降级为说明）。
    private let server: ServerConnection?

    /// 是否为演示会话（网络面板据此禁用真实请求）。
    private let isDemo: Bool

    /// 「切换服务器」回调；`nil` 时按钮禁用并说明替代入口。
    private let onSwitchServer: (() -> Void)?

    /// 内部面板选中态（无外部绑定时使用）。
    @State private var internalSelection: SettingsTab

    /// 是否展示「恢复默认设置」确认框。
    @State private var isResetConfirmationPresented = false

    /// 创建设置页。
    ///
    /// - Parameters:
    ///   - selection: 面板选中态的外部绑定；`nil` 时使用内部状态。
    ///   - settings: 设置存储，默认 ``PrismCore/AppSettings/shared``。
    ///   - server: 当前服务器（网络面板展示用）。
    ///   - isDemo: 是否为演示会话；演示模式下不发起真实网络请求。
    ///   - onSwitchServer: 「切换服务器」回调；`nil` 时按钮禁用。
    public init(
        selection: Binding<SettingsTab>? = nil,
        settings: AppSettings = .shared,
        server: ServerConnection? = nil,
        isDemo: Bool = false,
        onSwitchServer: (() -> Void)? = nil
    ) {
        self.settings = settings
        self.externalSelection = selection
        self.server = server
        self.isDemo = isDemo
        self.onSwitchServer = onSwitchServer
        self._internalSelection = State(initialValue: selection?.wrappedValue ?? .playback)
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.sm) {
                Picker("设置面板", selection: activeTab) {
                    ForEach(SettingsTab.allCases, id: \.self) { tab in
                        Label(tab.title, systemImage: tab.systemImage)
                            .tag(tab)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .accessibilityLabel("设置面板")

                Menu {
                    Button("恢复默认设置", systemImage: "arrow.counterclockwise", role: .destructive) {
                        isResetConfirmationPresented = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .help("更多设置操作")
                .accessibilityLabel("更多设置操作")
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)

            Divider()

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // 独立窗口 / 预览时约 720×520；放进 AppShell 的内容栏时由内容栏决定实际尺寸。
        .frame(minWidth: 600, idealWidth: 760, minHeight: 440, idealHeight: 560)
        .background(Palette.surface)
        .confirmationDialog(
            "恢复默认设置？",
            isPresented: $isResetConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("恢复默认", role: .destructive) {
                settings.reset()
                // 主题不在 AppSettings 里（§1.4 已冻结），单独复位。
                SettingsAppearanceStore.shared.appearance = .system
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("全部设置会恢复为初始值，包括界面语言（语言切换需要重启 App 才会生效）。此操作无法撤销。")
        }
    }

    // MARK: 内容区

    /// 右侧：面板标题 + 当前面板的表单。
    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                header

                panel

                Spacer(minLength: 0)
            }
            .padding(Spacing.xl)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// 面板标题与一句话说明。
    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(currentTab.title)
                .font(Typography.title)
                .foregroundStyle(Palette.textPrimary)

            Text(currentTab.settingsSummary)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// 当前面板的正文。
    @ViewBuilder
    private var panel: some View {
        switch currentTab {
        case .playback:
            PlaybackSettingsView(settings: settings)
        case .subtitles:
            SubtitleSettingsView(settings: settings)
        case .network:
            NetworkSettingsView(server: server, isDemo: isDemo, onSwitchServer: onSwitchServer)
        case .appearance:
            AppearanceSettingsView(settings: settings)
        case .servers:
            ServerSettingsView(server: server, onSwitchServer: onSwitchServer)
        case .about:
            AboutView()
        }
    }

    // MARK: 选中态

    /// 当前面板（外部绑定优先）。
    private var currentTab: SettingsTab {
        activeTab.wrappedValue
    }

    /// 统一后的可写绑定。
    private var activeTab: Binding<SettingsTab> {
        externalSelection ?? $internalSelection
    }

}

// MARK: - 面板元数据

extension SettingsTab {
    /// 面板标题下的一句话说明。
    var settingsSummary: LocalizedStringKey {
        switch self {
        case .playback: "画质、码率与播放行为。改动立即生效，正在播放的视频会从下一段开始使用新设置。"
        case .subtitles: "字幕语言与样式。样式只影响文本字幕，位图字幕保持原始画面。"
        case .network: "当前服务器、连接测试与超时策略。"
        case .appearance: "主题与界面语言。"
        case .servers: "已连接的服务器与登录状态。可在服务器列表中切换。"
        case .about: "版本、开源许可与免责声明。"
        }
    }
}

// MARK: - 预览

/// 预览用设置实例：独立 suite + 独立 key 前缀，不会污染真实偏好。
@MainActor
private func previewSettings() -> AppSettings {
    let defaults = UserDefaults(suiteName: "app.prism.Prism.preview.settings") ?? .standard
    return AppSettings(defaults: defaults, keyPrefix: "preview.")
}

/// 预览用服务器。
private let previewServer = ServerConnection(
    id: PreviewData.serverId,
    name: "客厅 Emby",
    baseURL: URL(string: "http://192.168.1.10:8096") ?? URL(filePath: "/")
)

#Preview("设置 · 播放（深色）") {
    SettingsView(settings: previewSettings(), server: previewServer)
        .prismTheme(PrismTheme(appearance: .dark))
        .frame(width: 720, height: 520)
}

#Preview("设置 · 字幕（浅色）") {
    @Previewable @State var tab = SettingsTab.subtitles
    SettingsView(selection: $tab, settings: previewSettings())
        .prismTheme(PrismTheme(appearance: .light))
        .frame(width: 720, height: 560)
}

#Preview("设置 · 外观（深色）") {
    @Previewable @State var tab = SettingsTab.appearance
    SettingsView(selection: $tab, settings: previewSettings())
        .prismTheme(PrismTheme(appearance: .dark))
        .frame(width: 720, height: 520)
}

#Preview("设置 · 关于（浅色）") {
    @Previewable @State var tab = SettingsTab.about
    SettingsView(selection: $tab, settings: previewSettings())
        .prismTheme(PrismTheme(appearance: .light))
        .frame(width: 720, height: 560)
}
