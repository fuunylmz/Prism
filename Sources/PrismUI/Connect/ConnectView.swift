import SwiftUI
import PrismCore
import EmbyAPI
import PrismData

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
    private let onConnected: @MainActor (ServerConnection, AuthSession, Credentials, Bool) async -> Void
    private let onCancel: (@MainActor @Sendable () -> Void)?

    @State private var model: ConnectViewModel
    @FocusState private var isAddressFocused: Bool

    /// 创建连接界面。
    ///
    /// - Parameter onConnected: 登录成功后的回调。`Credentials` 是本次输入的用户名与密码
    ///   （上层在「记住我」时会把它们存下来，下次启动直接重新登录），
    ///   最后一个参数是「是否记住登录」。
    public init(
        initialServer: ServerConnection? = nil,
        initialUsername: String = "",
        onCancel: (@MainActor @Sendable () -> Void)? = nil,
        onConnected: @escaping @MainActor (ServerConnection, AuthSession, Credentials, Bool) async -> Void
    ) {
        _model = State(initialValue: ConnectViewModel(initialServer: initialServer, initialUsername: initialUsername))
        self.onCancel = onCancel
        self.onConnected = onConnected
    }

    public var body: some View {
        ZStack {
            Palette.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, Spacing.xl)
                    .padding(.top, Spacing.xl)
                    .padding(.bottom, Spacing.md)

                ScrollView {
                    Group {
                        switch model.step {
                        case .findingServer:
                            ServerStepView(model: model)
                        case .signingIn, .connecting:
                            SignInStepView(model: model) {
                                await submitSignIn()
                            }
                        }
                    }
                    .frame(maxWidth: 460)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Spacing.xl)
                    .padding(.vertical, Spacing.md)
                }
                .scrollBounceBehavior(.basedOnSize)

                actionFooter
                    .frame(maxWidth: 460)
                    .padding(.horizontal, Spacing.xl)
                    .padding(.vertical, Spacing.md)
                    .background(.bar)

                if let onCancel {
                    Button("返回当前服务器", action: onCancel)
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.textSecondary)
                        .padding(.bottom, Spacing.md)
                }
            }
            .frame(maxWidth: 520, maxHeight: .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    @ViewBuilder
    private var actionFooter: some View {
        switch model.step {
        case .findingServer:
            manualConnectionFooter
        case .signingIn, .connecting:
            signInFooter
        }
    }

    private var manualConnectionFooter: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("手动输入地址")
                .font(Typography.headline)

            HStack(spacing: Spacing.sm) {
                TextField("http://192.168.1.10:8096", text: $model.addressText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isAddressFocused)
                    .onSubmit { Task { await model.connectManually() } }
                    .disabled(model.isBusy)

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

            Text("可以粘贴完整地址。不写端口默认 8096，不写协议默认 http。")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Typography.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var signInFooter: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Typography.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button {
                    Task { await submitSignIn() }
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
    }

    private func submitSignIn() async {
        guard let server = model.selectedServer,
              let auth = await model.signIn() else { return }
        await onConnected(
            server,
            auth,
            Credentials(username: model.username, password: model.password),
            model.rememberMe
        )
        model.finishConnecting()
    }
}

// MARK: - 第一步：找服务器

private struct ServerStepView: View {
    @Bindable var model: ConnectViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            recentSection

            if !model.recentServers.isEmpty {
                Divider()
            }

            discoveredSection
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
                        .background(Palette.surfaceElevated, in: RoundedRectangle(cornerRadius: Radius.card))
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
                        .background(Palette.surfaceElevated, in: RoundedRectangle(cornerRadius: Radius.card))
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

        }
        .onAppear { focusedField = .username }
    }
}
