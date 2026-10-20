import EmbyAPI
import PrismCore
import SwiftUI

// MARK: - 网络设置

/// 网络面板：当前服务器、连接测试、超时策略。
///
/// ## 为什么这里没有「服务器地址输入框」
///
/// v1.0 的连接流程是「添加服务器 → 登录」（欢迎页 / 服务器胶囊），设置里只做**只读回显**
/// 与**连通性诊断**。多服务器管理（重命名 / 设为默认 / 删除）属于 v1.1，见
/// `docs/research/ux-benchmark.md` §S15；现在给出可用的「切换服务器」按钮，
/// 但真正的切换入口仍然是侧边栏底部的服务器胶囊，避免两套切换逻辑打架。
///
/// ## 连接测试
///
/// 直接请求 `GET /System/Info/Public`（``ServerProbe``）——该端点不需要鉴权，
/// 因此**即使登录已失效也能判断服务器本身是否可达**，这正是排障时最想区分的两件事：
/// 「服务器挂了」还是「令牌过期了」。
struct NetworkSettingsView: View {
    /// 当前服务器；`nil` 表示未连接。
    let server: ServerConnection?

    /// 是否为演示会话（演示模式不发起真实网络请求）。
    let isDemo: Bool

    /// 「切换服务器」回调；`nil` 时按钮禁用并提示替代入口。
    var onSwitchServer: (() -> Void)?

    /// 连接测试状态。
    @State private var testState: ConnectionTestState = .idle

    /// 正在进行的测试任务（视图消失时取消）。
    @State private var testTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            serverSection
            testSection
            timeoutSection
        }
        .onDisappear {
            testTask?.cancel()
            testTask = nil
        }
    }

    // MARK: 服务器

    private var serverSection: some View {
        SettingsSection("当前服务器", footer: footerForServer) {
            SettingsRow("名称") {
                Text(verbatim: server?.name ?? "未连接")
                    .font(Typography.body)
                    .foregroundStyle(server == nil ? Palette.textSecondary : Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            SettingsRow("地址") {
                Text(verbatim: addressText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(server == nil ? Palette.textSecondary : Palette.textPrimary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            SettingsRow("连接方式", description: "局域网地址走 HTTP；公网访问建议在反向代理上启用 HTTPS。") {
                Text(verbatim: securityText)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }

            SettingsRow("切换服务器", description: "v1.0 只保存一台服务器；多服务器管理将在 v1.1 提供。") {
                Button("切换服务器…") {
                    onSwitchServer?()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(onSwitchServer == nil || isDemo)
                .help(onSwitchServer == nil ? "请使用侧边栏底部的服务器胶囊切换" : "切换当前服务器")
            }
        }
    }

    /// 服务器分组脚注：演示模式单独说明，避免用户以为地址是真实服务器。
    private var footerForServer: LocalizedStringKey? {
        if isDemo {
            return "当前为演示模式，地址不是真实服务器，不会产生任何网络请求。"
        }
        return nil
    }

    /// 地址文本。
    private var addressText: String {
        guard let server else { return "—" }
        return server.baseURL.absoluteString
    }

    /// 连接方式文本。
    private var securityText: String {
        guard let server else { return "—" }
        if server.isDemo { return "演示模式" }
        return server.isSecure ? "HTTPS" : "HTTP（明文）"
    }

    // MARK: 连接测试

    private var testSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SettingsSection("连接测试", footer: "测试只请求 /System/Info/Public（无需登录），因此能区分「服务器不可达」与「登录已失效」。") {
                SettingsRow("测试与服务器的连通性", description: "发送一次公开信息请求，返回服务器名称、版本与往返耗时。") {
                    HStack(spacing: Spacing.sm) {
                        if testState == .testing {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Button("测试连接") {
                            startTest()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!canTest)
                        .help(canTest ? "请求 /System/Info/Public" : "未连接服务器或处于演示模式")
                    }
                }
            }

            resultRow
        }
    }

    /// 测试结果（成功 / 失败 / 未测试）。
    @ViewBuilder
    private var resultRow: some View {
        switch testState {
        case .idle:
            EmptyView()

        case .testing:
            resultBadge(
                systemImage: "arrow.triangle.2.circlepath",
                tint: Palette.textSecondary,
                title: "正在连接…",
                detail: addressText
            )

        case let .succeeded(result):
            resultBadge(
                systemImage: "checkmark.circle.fill",
                tint: .green,
                title: "连接成功 · \(result.serverName)",
                detail: "服务器版本 \(result.version) · 往返 \(result.latencyMilliseconds) 毫秒"
            )

        case let .failed(message):
            resultBadge(
                systemImage: "xmark.octagon.fill",
                tint: .red,
                title: "连接失败",
                detail: message
            )
        }
    }

    /// 统一的结果条。
    ///
    /// - Parameters:
    ///   - systemImage: 左侧状态图标。
    ///   - tint: 图标颜色。
    ///   - title: 主文案。
    ///   - detail: 补充文案。
    /// - Returns: 结果条视图。
    private func resultBadge(
        systemImage: String,
        tint: Color,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(Palette.textPrimary)
                Text(verbatim: detail)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.surfaceElevated.opacity(0.65))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.separator, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    /// 是否允许发起测试。
    private var canTest: Bool {
        server != nil && !isDemo && testState != .testing
    }

    /// 发起一次连接测试。
    ///
    /// `Task` 继承视图的 `@MainActor` 隔离，因此可以直接写 `@State`；
    /// ``ServerProbe/fetchPublicInfo(baseURL:)`` 是 `nonisolated` 的异步方法，
    /// 实际网络等待发生在主线程之外。
    private func startTest() {
        guard let server, !isDemo else { return }
        testTask?.cancel()
        testState = .testing

        testTask = Task {
            let startedAt = Date()
            do {
                let info = try await ServerProbe().fetchPublicInfo(baseURL: server.baseURL)
                guard !Task.isCancelled else { return }
                let milliseconds = Int((Date().timeIntervalSince(startedAt) * 1000).rounded())
                testState = .succeeded(
                    ConnectionTestResult(
                        serverName: info.serverName.isEmpty ? server.name : info.serverName,
                        version: info.version.isEmpty ? "未知" : info.version,
                        latencyMilliseconds: max(milliseconds, 0)
                    )
                )
            } catch let error as EmbyError {
                guard !Task.isCancelled else { return }
                testState = .failed(String(localized: error.userMessage))
            } catch {
                guard !Task.isCancelled else { return }
                testState = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: 超时

    private var timeoutSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SettingsSection("超时") {
                SettingsRow(
                    "请求超时",
                    description: "普通 API 请求的固定超时。网络抖动时请求会先重试再报错，不会一直卡在加载态。"
                ) {
                    Text(verbatim: "\(Int(EmbyRequestTimeout.defaultSeconds)) 秒")
                        .font(Typography.caption)
                        .monospacedDigit()
                        .foregroundStyle(Palette.textSecondary)
                }

                SettingsRow(
                    "连接测试超时",
                    description: "连接测试单独使用更短的超时，局域网连不上时能更快给出结论。",
                    showsDivider: false
                ) {
                    Text(verbatim: "\(Int(EmbyRequestTimeout.probeSeconds)) 秒")
                        .font(Typography.caption)
                        .monospacedDigit()
                        .foregroundStyle(Palette.textSecondary)
                }
            }

            SettingsNote("v1.0 的超时是固定值（`AppSettings` 未包含该项）。自定义超时依赖 `PrismCore` 新增设置项，计划在 v1.1 提供；临时需要更长的超时请改用局域网地址。")
        }
    }
}

// MARK: - 超时常量

/// 网络面板展示用的超时常量。
///
/// 值来自 `EmbyAPI` 的实现：普通请求用 ``EmbyAPI/RequestBuilder/defaultTimeout``，
/// 连接测试用 ``EmbyAPI/ServerProbe`` 的默认值。这里只做**展示**，
/// 不复制实现——两处若将来分开，改这一个文件即可。
enum EmbyRequestTimeout {
    /// 普通 API 请求超时（秒）。
    static let defaultSeconds: TimeInterval = RequestBuilder.defaultTimeout
    /// 连接测试超时（秒）。
    static let probeSeconds: TimeInterval = 10
}

// MARK: - 连接测试状态

/// 连接测试结果。
struct ConnectionTestResult: Equatable {
    /// 服务器自报名称。
    let serverName: String
    /// 服务器版本号。
    let version: String
    /// 往返耗时（毫秒）。
    let latencyMilliseconds: Int
}

/// 连接测试的四种状态。
enum ConnectionTestState: Equatable {
    /// 尚未测试。
    case idle
    /// 正在测试。
    case testing
    /// 成功。
    case succeeded(ConnectionTestResult)
    /// 失败，附带面向用户的错误文案。
    case failed(String)
}

// MARK: - 服务器面板

/// 服务器面板：当前连接信息 + 切换入口 + 版本范围说明。
///
/// 与网络面板的分工：网络面板偏「诊断」（连通性、超时），本面板偏「身份」
/// （连的是哪台服务器、哪个用户、是否演示模式）。多服务器管理属于 v1.1。
struct ServerSettingsView: View {
    /// 当前服务器。
    let server: ServerConnection?
    /// 「切换服务器」回调。
    var onSwitchServer: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            SettingsSection("已连接") {
                SettingsRow("服务器") {
                    Text(verbatim: server?.name ?? "未连接")
                        .font(Typography.body)
                        .foregroundStyle(server == nil ? Palette.textSecondary : Palette.textPrimary)
                }

                SettingsRow("地址") {
                    Text(verbatim: server?.baseURL.absoluteString ?? "—")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Palette.textSecondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                SettingsRow("上次连接") {
                    Text(verbatim: lastConnectedText)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                }

                SettingsRow("切换服务器", description: "也可以随时点击侧边栏底部的服务器胶囊。", showsDivider: false) {
                    Button("切换服务器…") {
                        onSwitchServer?()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(onSwitchServer == nil)
                }
            }

            SettingsNote("v1.0 只保存一台服务器。添加 / 重命名 / 设为默认 / 删除服务器，以及多服务器并行登录，属于 v1.1 范围。")
        }
    }

    /// 上次连接时间（相对时间，避免用户换算时区）。
    private var lastConnectedText: String {
        guard let date = server?.lastConnectedAt else { return "未知" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - 预览

/// 预览用服务器（假地址，不会发起请求）。
private let networkPreviewServer = ServerConnection(
    id: PreviewData.serverId,
    name: "客厅 Emby",
    baseURL: URL(string: "http://192.168.1.10:8096") ?? URL(filePath: "/"),
    lastConnectedAt: Date()
)

#Preview("网络设置 · 深色") {
    ScrollView {
        NetworkSettingsView(server: networkPreviewServer, isDemo: false)
            .padding(Spacing.xl)
    }
    .frame(width: 620, height: 640)
    .background(Palette.surface)
    .prismTheme(PrismTheme(appearance: .dark))
}

#Preview("网络设置 · 未连接（浅色）") {
    ScrollView {
        NetworkSettingsView(server: nil, isDemo: false)
            .padding(Spacing.xl)
    }
    .frame(width: 620, height: 640)
    .background(Palette.surface)
    .prismTheme(PrismTheme(appearance: .light))
}

#Preview("网络设置 · 演示模式") {
    ScrollView {
        NetworkSettingsView(
            server: ServerConnection(
                id: "preview-demo",
                name: "演示服务器",
                baseURL: URL(string: "https://demo.prism.invalid") ?? URL(filePath: "/"),
                isDemo: true
            ),
            isDemo: true
        )
        .padding(Spacing.xl)
    }
    .frame(width: 620, height: 640)
    .background(Palette.surface)
    .prismTheme(PrismTheme(appearance: .dark))
}

#Preview("服务器设置 · 深色") {
    ScrollView {
        ServerSettingsView(server: networkPreviewServer, onSwitchServer: {})
            .padding(Spacing.xl)
    }
    .frame(width: 620, height: 420)
    .background(Palette.surface)
    .prismTheme(PrismTheme(appearance: .dark))
}
