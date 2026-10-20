import SwiftUI

// MARK: - 服务器胶囊

/// 侧边栏底部的服务器胶囊。
///
/// 展示当前服务器名、连接状态点与当前用户头像占位；点击（或 ⌘⇧S）展开菜单：
/// 用户信息 / 服务器列表（v1.0 只做切换）/ 设置… / 退出登录。
///
/// 约定：
/// - 头像使用「首字母 + 服务器色」的圆形占位；真实头像由用户资料工单接入
///   （`EmbyUser.primaryImageTag` + 图片加载器），此处不发起任何网络请求。
/// - 每台服务器分配一个稳定色相（对 `serverId` 做确定性哈希），
///   同名服务器也能靠颜色区分（`docs/research/ux-benchmark.md` §2.4）。
/// - 多服务器聚合 / 管理服务器 / 添加服务器属于 v1.1，v1.0 只保留切换。
struct ServerPill: View {
    /// 导航模型。
    @Bindable var model: NavigationModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var isConfirmingSignOut = false

    var body: some View {
        Button {
            model.isServerSwitcherPresented.toggle()
        } label: {
            pillLabel
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
        .popover(isPresented: $model.isServerSwitcherPresented, arrowEdge: .top) {
            menu
        }
        .confirmationDialog(
            "退出登录？",
            isPresented: $isConfirmingSignOut,
            titleVisibility: .visible
        ) {
            Button("退出登录", role: .destructive) {
                model.requestSignOut()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清除本机保存的登录信息，服务器上的数据不受影响。")
        }
        .help("服务器：\(model.currentServerName)（⌘⇧S）")
        .accessibilityLabel("当前服务器 \(model.currentServerName)，\(model.currentServerStatus.title)")
    }

    // MARK: 胶囊本体

    private var pillLabel: some View {
        HStack(spacing: Spacing.sm) {
            avatar(size: 28, showsStatus: true)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.currentServerName)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(model.currentUserName)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Spacing.xs)

            if model.hasMultipleServers {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs + 2)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.textPrimary.opacity(isHovering ? 0.10 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.separator, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    // MARK: 头像占位

    /// 圆形头像占位：首字母 + 服务器色；右下角可挂连接状态点。
    ///
    /// - Parameters:
    ///   - size: 直径（pt）。
    ///   - showsStatus: 是否显示右下角状态点。
    /// - Returns: 头像视图。
    private func avatar(size: CGFloat, showsStatus: Bool) -> some View {
        let color = serverColor(for: model.currentServer?.id ?? "unconnected")
        let initial = model.currentUser?.initial ?? "?"

        return ZStack {
            Circle()
                .fill(color.opacity(0.22))

            Text(initial)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
        .overlay {
            Circle()
                .strokeBorder(color.opacity(0.45), lineWidth: 1)
        }
        .overlay(alignment: .bottomTrailing) {
            if showsStatus {
                Circle()
                    .fill(model.currentServerStatus.color)
                    .frame(width: size * 0.30, height: size * 0.30)
                    .overlay {
                        Circle().strokeBorder(Palette.surface, lineWidth: 1.5)
                    }
                    .offset(x: 1, y: 1)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: 菜单

    private var menu: some View {
        VStack(alignment: .leading, spacing: 0) {
            userHeader

            Divider()
                .padding(.vertical, Spacing.xs)

            serverSection

            Divider()
                .padding(.vertical, Spacing.xs)

            ServerMenuRow(title: "设置…", systemImage: "gearshape", shortcut: "⌘,") {
                model.isServerSwitcherPresented = false
                model.openSettings(.servers)
            }

            ServerMenuRow(
                title: "退出登录",
                systemImage: "rectangle.portrait.and.arrow.right",
                isEnabled: model.currentUser != nil,
                isDestructive: true
            ) {
                model.isServerSwitcherPresented = false
                isConfirmingSignOut = true
            }
        }
        .padding(Spacing.xs)
        .frame(width: 260)
    }

    private var userHeader: some View {
        HStack(spacing: Spacing.sm) {
            avatar(size: 36, showsStatus: false)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.currentUserName)
                    .font(Typography.headline)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)

                Text(roleDescription)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(Spacing.sm)
        .accessibilityElement(children: .combine)
    }

    private var roleDescription: String {
        guard let user = model.currentUser else {
            return "\(model.currentServerName) · 未登录"
        }
        return "\(model.currentServerName) · \(user.isAdministrator ? "管理员" : "用户")"
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("服务器")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, Spacing.sm)
                .padding(.bottom, 2)

            if model.servers.isEmpty {
                Text("尚未连接服务器")
                    .font(.callout)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
            } else {
                ForEach(model.servers) { server in
                    ServerMenuRow(
                        title: server.name,
                        status: model.status(for: server.id),
                        isSelected: server.id == model.currentServer?.id
                    ) {
                        model.selectServer(id: server.id)
                    }
                }
            }

            ServerMenuRow(
                title: "管理服务器…",
                systemImage: "externaldrive.connected.to.line.below",
                isEnabled: false,
                badge: "v1.1"
            ) {
                // v1.1 提供多服务器管理；v1.0 仅支持切换。
            }
        }
    }

    // MARK: 服务器色

    /// 为服务器 id 计算稳定的色相。
    ///
    /// 不能用 `hashValue`：Swift 的哈希每次进程启动都会重新加盐，颜色会跳变。
    /// 这里用 FNV-1a 对 UTF-8 字节做确定性哈希。
    ///
    /// - Parameter serverID: 服务器 id。
    /// - Returns: 该服务器的身份色。
    private func serverColor(for serverID: String) -> Color {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in serverID.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.85)
    }
}

// MARK: - 状态颜色

extension ServerStatus {
    /// 状态点颜色（语义色，跟随系统外观）。
    var color: Color {
        switch self {
        case .connected: .green
        case .connecting: .yellow
        case .unauthorized: .orange
        case .offline: .gray
        case .unsupported: .red
        }
    }
}

// MARK: - 菜单行

/// 服务器胶囊浮层中的一行菜单项，带 hover 高亮与键盘可达性。
private struct ServerMenuRow: View {
    /// 主文案。
    let title: String
    /// 左侧 SF Symbol（与 ``status`` 二选一）。
    var systemImage: String? = nil
    /// 右侧快捷键提示。
    var shortcut: String? = nil
    /// 左侧状态点（服务器行使用）。
    var status: ServerStatus? = nil
    /// 是否为当前项（右侧打勾）。
    var isSelected = false
    /// 是否可用。
    var isEnabled = true
    /// 是否为危险操作（红色文字）。
    var isDestructive = false
    /// 版本角标（例如 v1.1）。
    var badge: String? = nil
    /// 点击动作。
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                if let status {
                    Circle()
                        .fill(status.color)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .frame(width: 16, alignment: .center)
                        .accessibilityHidden(true)
                }

                Text(title)
                    .lineLimit(1)

                Spacer(minLength: Spacing.sm)

                if let badge {
                    Text(badge)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }

                if let shortcut {
                    Text(shortcut)
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                }

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                        .accessibilityHidden(true)
                }
            }
            .font(.callout)
            .foregroundStyle(isDestructive ? Color.red : Palette.textPrimary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: Radius.poster, style: .continuous)
                    .fill(isHovering && isEnabled ? Palette.textPrimary.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
        .onHover { hovering in
            if reduceMotion {
                isHovering = hovering
            } else {
                withAnimation(.easeOut(duration: Motion.quick)) {
                    isHovering = hovering
                }
            }
        }
        .help(isEnabled ? title : "\(title)（v1.1 提供）")
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [title]
        if let status { parts.append(status.title) }
        if isSelected { parts.append("当前服务器") }
        if let badge { parts.append("版本 \(badge)") }
        return parts.joined(separator: "，")
    }
}
