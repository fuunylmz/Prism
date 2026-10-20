import SwiftUI

// MARK: - 侧边栏

/// 三栏布局的侧边栏。
///
/// 结构（`docs/research/ux-benchmark.md` §2.2 / §2.3）：
/// - 顶部：产品名；
/// - 媒体库组：首页 ⌘1、电影 ⌘2、剧集 ⌘3；
/// - 工具组：搜索 ⌘F、下载（v1.1，禁用 + 版本角标）；
/// - 底部固定：设置 ⌘, 与服务器胶囊 ⌘⇧S。
///
/// 选中态使用 `.listStyle(.sidebar)` 的系统选中色，不自定义选中背景；
/// hover 只叠加一层极淡的语义色，且尊重「减弱动态效果」。
/// 所有行都是 `List(selection:)` 的 tag 行，因此支持 ↑↓ 键盘选择与 VoiceOver。
struct SidebarView: View {
    /// 导航模型。
    @Bindable var model: NavigationModel

    /// 媒体库分组。
    private let libraryItems: [SidebarItem] = [.home, .movies, .series]
    /// 工具分组。
    private let toolItems: [SidebarItem] = [.search, .downloads]

    var body: some View {
        VStack(spacing: 0) {
            brandHeader

            List(selection: selectionBinding) {
                Section("媒体库") {
                    ForEach(libraryItems, id: \.self) { item in
                        SidebarRow(item: item)
                    }
                }

                Section("工具") {
                    ForEach(toolItems, id: \.self) { item in
                        SidebarRow(item: item)
                    }
                }
            }
            .listStyle(.sidebar)

            footer
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
    }

    // MARK: 选中绑定

    /// 把 `List` 的可空选中项映射到模型；清空选择不改变当前页面。
    private var selectionBinding: Binding<SidebarItem?> {
        Binding(
            get: { model.selection },
            set: { newValue in
                guard let newValue else { return }
                model.select(newValue)
            }
        )
    }

    // MARK: 顶部品牌

    private var brandHeader: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)

            Text("Prism")
                .font(Typography.title)
                .foregroundStyle(Palette.textPrimary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.sm)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: 底部固定区

    private var footer: some View {
        VStack(spacing: Spacing.xs) {
            Divider()

            SettingsFooterRow(isSelected: model.selection == .settings) {
                model.openSettings(model.settingsTab)
            }

            ServerPill(model: model)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.top, Spacing.xs)
        .padding(.bottom, Spacing.sm)
    }
}

// MARK: - 列表行

/// 侧边栏的一行：图标 + 标题 + 快捷键提示 / 版本角标，带 hover 高亮。
private struct SidebarRow: View {
    /// 该行对应的导航项。
    let item: SidebarItem

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Label {
                Text(item.title)
            } icon: {
                Image(systemName: item.systemImage)
                    .frame(width: 18, alignment: .center)
            }

            Spacer(minLength: Spacing.xs)

            if let badge = item.versionBadge {
                Text(badge)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, Spacing.xs + 1)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Palette.textPrimary.opacity(0.08)))
                    .accessibilityLabel("版本 \(badge)")
            } else if let hint = item.shortcutHint {
                Text(hint)
                    .font(Typography.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering in
            if reduceMotion {
                isHovering = hovering
            } else {
                withAnimation(.easeOut(duration: Motion.quick)) {
                    isHovering = hovering
                }
            }
        }
        .listRowBackground(
            isHovering ? Palette.textPrimary.opacity(0.06) : Color.clear
        )
        .disabled(!item.isAvailable)
        .help(helpText)
        .accessibilityLabel(accessibilityText)
        .tag(item)
    }

    private var helpText: String {
        guard let hint = item.shortcutHint else { return item.title }
        return item.isAvailable ? "\(item.title)（\(hint)）" : "\(item.title)：v1.1 提供"
    }

    private var accessibilityText: String {
        if !item.isAvailable {
            return "\(item.title)，v1.1 提供"
        }
        if let hint = item.shortcutHint {
            return "\(item.title)，快捷键 \(hint)"
        }
        return item.title
    }
}

// MARK: - 设置行

/// 侧边栏底部的「设置」行（不随列表滚动）。
private struct SettingsFooterRow: View {
    /// 当前是否处于设置路由。
    let isSelected: Bool
    /// 点击动作。
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                Label {
                    Text("设置")
                } icon: {
                    Image(systemName: "gearshape")
                        .frame(width: 18, alignment: .center)
                }

                Spacer(minLength: Spacing.xs)

                Text("⌘,")
                    .font(Typography.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: Radius.poster, style: .continuous)
                    .fill(background)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if reduceMotion {
                isHovering = hovering
            } else {
                withAnimation(.easeOut(duration: Motion.quick)) {
                    isHovering = hovering
                }
            }
        }
        .help("设置（⌘,）")
        .accessibilityLabel("设置，快捷键 ⌘,")
    }

    private var background: Color {
        if isSelected {
            return Palette.accent.opacity(0.18)
        }
        return isHovering ? Palette.textPrimary.opacity(0.06) : .clear
    }
}
