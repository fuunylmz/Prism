import PrismCore
import SwiftUI

// MARK: - 外观设置存储

/// 外观偏好（主题）的持久化容器。
///
/// ## 为什么单独一个 store
///
/// `docs/ARCHITECTURE.md` §1.4 把 ``PrismCore/AppSettings`` 冻结了，其中**没有**主题项；
/// 而主题必须由 AppShell 在最外层挂载（``SwiftUI/View/prismTheme(_:)``），
/// 设置页只负责写偏好。因此这里用一个最小的 `@Observable` 容器承担「设置页 ↔ 外壳」
/// 之间的唯一纽带：
///
/// ```swift
/// // RootShell 里把主题改成跟随设置（一行）：
/// .prismTheme(SettingsAppearanceStore.shared.theme)
/// ```
///
/// 未接入时设置页仍可正常读写，只是不会立刻改变窗口外观（需要重启或接入后才生效）。
@MainActor
@Observable
public final class SettingsAppearanceStore {
    /// 全局共享实例。
    public static let shared = SettingsAppearanceStore()

    /// 持久化容器。
    private let defaults: UserDefaults

    /// `UserDefaults` 键名。
    private let key = "prism.settings.appearance"

    /// 外观策略；写入即持久化。
    public var appearance: PrismTheme.Appearance {
        didSet {
            guard appearance != oldValue else { return }
            defaults.set(appearance.rawValue, forKey: key)
        }
    }

    /// 供 ``SwiftUI/View/prismTheme(_:)`` 直接使用的主题值。
    public var theme: PrismTheme {
        PrismTheme(appearance: appearance)
    }

    /// 创建 store。
    ///
    /// - Parameter defaults: 持久化容器，测试可注入独立 suite。
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: key)
        self.appearance = stored.flatMap(PrismTheme.Appearance.init(rawValue:)) ?? .system
    }
}

// MARK: - 外观设置

/// 外观面板：主题与界面语言。
///
/// - **主题**立即生效（前提是外壳用 ``SettingsAppearanceStore`` 挂载主题）；
/// - **语言**必须重启：String Catalog 在进程启动时加载进 `Bundle`，运行时无法热替换，
///   这一点在界面上明确写出来，避免用户以为开关坏了。
struct AppearanceSettingsView: View {
    /// 设置存储（语言）。
    @Bindable var settings: AppSettings

    /// 外观 store（主题）。
    @Bindable private var appearanceStore: SettingsAppearanceStore

    /// 当前生效的本地化语言（用于判断「改了但还没重启」）。
    private let activeLocalization: String

    /// 创建外观面板。
    ///
    /// - Parameters:
    ///   - settings: 设置存储。
    ///   - appearanceStore: 外观 store，默认 ``SettingsAppearanceStore/shared``。
    init(settings: AppSettings, appearanceStore: SettingsAppearanceStore = .shared) {
        self.settings = settings
        self._appearanceStore = Bindable(wrappedValue: appearanceStore)
        self.activeLocalization = Bundle.main.preferredLocalizations.first ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            SettingsSection("主题") {
                SettingsPicker(
                    "外观",
                    description: "「跟随系统」会随 macOS 的浅色 / 深色设置自动切换。",
                    showsDivider: false,
                    selection: $appearanceStore.appearance,
                    options: PrismTheme.Appearance.allCases,
                    style: .segmented,
                    width: 222
                ) { appearance in
                    appearance.settingsLabel
                }
            }

            SettingsNote("v1.0 只提供主题与语言两项外观设置。海报尺寸、网格密度、强调色等属于 v1.1，见 UX 规格 §S15。")

            SettingsSection("语言", footer: "界面语言保存在本地，不会同步到服务器。") {
                SettingsPicker(
                    "界面语言",
                    description: "「跟随系统」使用 macOS 的「语言与地区」设置。",
                    showsDivider: false,
                    selection: $settings.language,
                    options: AppLanguage.allCases,
                    width: 172
                ) { language in
                    language.settingsLabel
                }
            }

            if requiresRestart {
                SettingsNote("语言已更改，**重启 Prism 后生效**。文字资源（String Catalog）在启动时随 Bundle 一起加载，运行时无法热切换，因此这里不做即时刷新。", kind: .warning)
            }
        }
    }

    /// 选中的语言是否与当前进程实际加载的语言不一致。
    ///
    /// 「跟随系统」永远视为一致：它解析出的就是系统语言，改系统语言同样要重启。
    private var requiresRestart: Bool {
        guard let expected = settings.language.localeIdentifierPrefix else { return false }
        guard !activeLocalization.isEmpty else { return false }
        return !activeLocalization.lowercased().hasPrefix(expected.lowercased())
    }
}

// MARK: - 枚举文案

extension PrismTheme.Appearance {
    /// 设置页显示名。
    var settingsLabel: LocalizedStringKey {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
}

extension AppLanguage {
    /// 设置页显示名。
    var settingsLabel: LocalizedStringKey {
        switch self {
        case .system: "跟随系统"
        case .zhHans: "简体中文"
        case .en: "English"
        }
    }

    /// 与 `Bundle.main.preferredLocalizations` 比较用的语言前缀；`system` 为 `nil`。
    var localeIdentifierPrefix: String? {
        switch self {
        case .system: nil
        case .zhHans: "zh"
        case .en: "en"
        }
    }
}

// MARK: - 预览

#Preview("外观设置 · 深色") {
    ScrollView {
        AppearanceSettingsView(
            settings: AppSettings(defaults: .standard, keyPrefix: "preview.appearance."),
            appearanceStore: SettingsAppearanceStore(defaults: .standard)
        )
        .padding(Spacing.xl)
    }
    .frame(width: 620, height: 520)
    .background(Palette.surface)
    .prismTheme(PrismTheme(appearance: .dark))
}

#Preview("外观设置 · 浅色") {
    ScrollView {
        AppearanceSettingsView(
            settings: AppSettings(defaults: .standard, keyPrefix: "preview.appearance."),
            appearanceStore: SettingsAppearanceStore(defaults: .standard)
        )
        .padding(Spacing.xl)
    }
    .frame(width: 620, height: 520)
    .background(Palette.surface)
    .prismTheme(PrismTheme(appearance: .light))
}
