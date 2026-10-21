import SwiftUI
import PrismCore
import EmbyAPI

// MARK: - 连接与登录

/// 服务器连接与登录界面。
///
/// 三步：
/// 1. 找服务器（自动发现 + 手动输入地址）
/// 2. 登录（用户名 / 密码）
/// 3. 完成，把会话交给上层
///
/// 这是用户第一次打开 Prism 看到的东西，所以文案要具体、错误要说清原因。
public struct ConnectView: View {
    /// 登录成功回调。
    ///
    /// 传服务器与登录结果两份数据，而不是一个 `PrismSession`——
    /// 因为持久化（会话 + 服务器列表）需要 `ServerConnection`，
    /// 由上层统一做，界面不碰存储。
    private let onConnected: @MainActor (ServerConnection, AuthSession, Bool) async -> Void

    @State private var model = ConnectViewModel()

    /// 创建连接界面。
    ///
    /// - Parameter onConnected: 登录成功后的回调，第三个参数是「是否记住登录」。
    public init(onConnected: @escaping @MainActor (ServerConnection, AuthSession, Bool) async -> Void) {
        self.onConnected = onConnected
    }

    public var body: some View {
        ZStack {
            Palette.surface.ignoresSafeArea()

            VStack(spacing: Spacing.xl) {
                header

                Group {
                    switch model.step {
                    case .findingServer:
                        ServerStepView(model: model)
                    case .signingIn, .connecting:
                        SignInStepView(model: model) {
                            if let server = model.selectedServer,
                               let auth = await model.signIn() {
                                await onConnected(server, auth, model.rememberMe)
                                model.finishConnecting()
                            }
                        }
                    }
                }
                .frame(maxWidth: 460)
                .padding(Spacing.xl)
                .background(Palette.surfaceElevated, in: RoundedRectangle(cornerRadius: Radius.panel))
            }
            .padding(Spacing.xxl)
        }
        .task { await model.startDiscovery() }
    }

    private var header: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Palette.accent)
            Text("Prism")
                .font(Typography.titleLarge)
            Text(model.step == .findingServer ? "连接到你的 Emby 服务器" : "登录")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
        }
    }
}

// MARK: - 第一步：找服务器

private struct ServerStepView: View {
    @Bindable var model: ConnectViewModel
    @FocusState private var isAddressFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            recentSection

            if !model.recentServers.isEmpty {
                Divider()
            }

            discoveredSection

            Divider()

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("手动输入地址")
                    .font(Typography.headline)

                TextField("http://192.168.1.10:8096", text: $model.addressText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isAddressFocused)
                    .onSubmit { Task { await model.connectManually() } }
                    .disabled(model.isBusy)

                Text("可以粘贴完整地址。不写端口默认 8096，不写协议默认 http。")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Typography.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button {
                    Task { await model.connectManually() }
                } label: {
                    if model.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("连接")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy || model.addressText.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// 最近使用过的服务器：退出登录后不必重新手打地址。
    @ViewBuilder
    private var recentSection: some View {
        if !model.recentServers.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("最近使用")
                    .font(Typography.headline)

                ForEach(model.recentServers) { server in
                    Button {
                        Task { await model.select(server) }
                    } label: {
                        HStack {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(Palette.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name).font(Typography.body)
                                Text(server.baseURL.absoluteString)
                                    .font(Typography.caption)
                                    .foregroundStyle(Palette.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(Palette.textSecondary)
                        }
                        .contentShape(Rectangle())
                        .padding(Spacing.sm)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var discoveredSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text("局域网内的服务器")
                    .font(Typography.headline)
                Spacer()
                if model.isDiscovering {
                    ProgressView().controlSize(.small)
                } else {
                    Button("重新搜索") {
                        Task { await model.startDiscovery() }
                    }
                    .buttonStyle(.link)
                    .font(Typography.caption)
                }
            }

            if model.discovered.isEmpty {
                Text(model.isDiscovering ? "正在搜索…" : "没有自动找到服务器，请手动输入地址。")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            } else {
                ForEach(model.discovered) { server in
                    Button {
                        Task { await model.select(server) }
                    } label: {
                        HStack {
                            Image(systemName: "server.rack")
                                .foregroundStyle(Palette.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name).font(Typography.body)
                                Text(server.baseURL.absoluteString)
                                    .font(Typography.caption)
                                    .foregroundStyle(Palette.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(Palette.textSecondary)
                        }
                        .contentShape(Rectangle())
                        .padding(Spacing.sm)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - 第二步：登录

private struct SignInStepView: View {
    @Bindable var model: ConnectViewModel
    let onSubmit: @MainActor () async -> Void

    @FocusState private var focusedField: Field?

    private enum Field { case username, password }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            if let server = model.selectedServer {
                HStack {
                    Image(systemName: "server.rack")
                        .foregroundStyle(Palette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.name).font(Typography.body)
                        Text(server.baseURL.absoluteString)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    Spacer()
                    Button("换一个") { model.backToServerSelection() }
                        .buttonStyle(.link)
                        .font(Typography.caption)
                }
                .padding(Spacing.sm)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card))
            }

            TextField("用户名", text: $model.username)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .username)
                .onSubmit { focusedField = .password }
                .disabled(model.isBusy)

            SecureField("密码", text: $model.password)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .password)
                .onSubmit { Task { await onSubmit() } }
                .disabled(model.isBusy)

            Toggle("记住我（下次启动免登录）", isOn: $model.rememberMe)
                .toggleStyle(.checkbox)
                .font(Typography.caption)
                .disabled(model.isBusy)

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Typography.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button {
                    Task { await onSubmit() }
                } label: {
                    if model.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("登录")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy || model.username.isEmpty || model.step == .connecting)
                .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { focusedField = .username }
    }
}
