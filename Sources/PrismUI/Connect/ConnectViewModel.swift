import Foundation
import Observation
import PrismCore
import EmbyAPI
import PrismData

// MARK: - 连接流程状态机

/// 连接与登录的视图模型。
///
/// 只做「状态 + 网络调用」，不碰磁盘——持久化由上层（`SessionBootstrapper`）统一做。
@MainActor
@Observable
public final class ConnectViewModel {
    /// 当前步骤。
    public enum Step: Sendable, Equatable {
        case findingServer
        case signingIn
        /// 已登录成功，正在持久化会话并切换界面。
        ///
        /// 单独一态是为了让「登录」按钮在切换完成前保持禁用——
        /// 否则 `signIn()` 返回后到主界面出现之间有一段窗口，用户能连点两次。
        case connecting
    }

    /// 当前步骤。
    public private(set) var step: Step = .findingServer

    /// 自动发现的服务器。
    public private(set) var discovered: [DiscoveredServer] = []

    /// 曾经成功连接过的服务器（最近使用优先）。
    ///
    /// 退出登录 / token 失效后，用户不该被要求重新手打一遍地址——
    /// 服务器记录本来就保留着（见 `SessionRestoration.invalidate` 的说明）。
    public private(set) var recentServers: [ServerConnection] = []
    /// 是否正在自动发现。
    public private(set) var isDiscovering = false
    /// 是否有网络操作在进行（连接校验 / 登录）。
    public private(set) var isBusy = false
    /// 错误提示（已转成用户能懂的话）。
    public private(set) var errorMessage: String?

    /// 手动输入的地址。
    public var addressText = ""
    /// 用户名。
    public var username = ""
    /// 密码。
    public var password = ""

    /// 是否把登录状态保存到本机（下次启动免登录）。
    public var rememberMe = true

    /// 已选定的服务器。
    public private(set) var selectedServer: ServerConnection?

    private let discovery: ServerDiscovery
    private let registry: ServerRegistry
    private var discoveryTask: Task<Void, Never>?
    private var client: EmbyClient?

    /// 创建视图模型。
    ///
    /// - Parameters:
    ///   - discovery: 发现器；默认用真实 UDP 广播。
    ///   - registry: 服务器记录；默认与登录流程共用同一个 `UserDefaults` 域。
    public init(
        discovery: ServerDiscovery = ServerDiscovery(),
        registry: ServerRegistry = ServerRegistry(),
        initialServer: ServerConnection? = nil,
        initialUsername: String = ""
    ) {
        self.discovery = discovery
        self.registry = registry
        if let initialServer {
            selectedServer = initialServer
            step = .signingIn
        }
        username = initialUsername
    }

    // MARK: 第一步

    /// 开始（或重新开始）局域网发现。
    public func startDiscovery() async {
        discoveryTask?.cancel()
        errorMessage = nil
        discovered = []
        isDiscovering = true

        // 历史服务器与局域网发现并行：前者是本地读，几乎瞬时。
        recentServers = await registry.servers()

        discoveryTask = Task { [weak self] in
            guard let self else { return }
            let found = await self.discovery.discoverAll(timeout: .seconds(3))
            guard !Task.isCancelled else { return }
            self.discovered = found
            self.isDiscovering = false
        }
    }

    /// 手动输入地址并校验。
    public func connectManually() async {
        let input = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        do {
            let (server, _) = try await discovery.validate(urlString: input)
            selectedServer = server
            step = .signingIn
        } catch let error as EmbyError {
            errorMessage = Self.message(for: error, address: input)
        } catch {
            errorMessage = "无法连接到 \(input)，请检查地址与网络。"
        }
    }

    /// 选中一台历史服务器（直接进入登录步骤，不必再探测）。
    ///
    /// - Parameter server: 历史记录里的服务器。
    public func select(_ server: ServerConnection) async {
        errorMessage = nil
        selectedServer = server
        step = .signingIn
    }

    /// 选中一个自动发现的服务器。
    public func select(_ server: DiscoveredServer) async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        do {
            let (connection, _) = try await discovery.validate(urlString: server.baseURL.absoluteString)
            selectedServer = connection
            step = .signingIn
        } catch let error as EmbyError {
            errorMessage = Self.message(for: error, address: server.baseURL.absoluteString)
        } catch {
            errorMessage = "无法连接到 \(server.name)。"
        }
    }

    // MARK: 第二步

    /// 登录。
    ///
    /// - Returns: 成功时返回会话；失败返回 `nil`，并把错误写进 ``errorMessage``。
    ///
    /// - Note: 成功时**不会**复位 ``isBusy``，而是进入 ``Step/connecting``，
    ///   由上层在会话落地后调用 ``finishConnecting()``。这样「登录」按钮
    ///   在整个切换过程中都保持禁用，避免重复提交。
    public func signIn() async -> AuthSession? {
        guard let server = selectedServer else { return nil }

        isBusy = true
        errorMessage = nil

        let client = EmbyClient(server: server, identity: ClientIdentity.current())
        self.client = client

        do {
            let session = try await client.authenticate(username: username, password: password)
            step = .connecting
            return session
        } catch let error as EmbyError {
            isBusy = false
            switch error {
            case .unauthorized:
                // 401 = 凭据不对。不要说「未授权」——用户看不懂。
                errorMessage = "用户名或密码不正确。"
            case .forbidden:
                // 403 是另一回事：账号被禁用 / 不允许登录。让用户反复试密码是死路。
                errorMessage = "该账号被服务器禁止登录，请联系服务器管理员。"
            case .serverUnreachable, .timeout:
                errorMessage = "无法连接到服务器，请检查网络后重试。"
            default:
                errorMessage = String(localized: error.userMessage)
            }
            return nil
        } catch {
            isBusy = false
            errorMessage = "登录失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// 上层完成会话持久化后调用，解除 ``Step/connecting``。
    ///
    /// 失败（例如磁盘写不进去）也调用它——用户这一轮已经登录成功，
    /// 不该卡在「正在连接」。
    public func finishConnecting() {
        isBusy = false
        step = .signingIn
    }

    /// 回到第一步（换服务器）。
    public func backToServerSelection() {
        step = .findingServer
        selectedServer = nil
        password = ""
        errorMessage = nil
        client = nil
    }

    // MARK: 文案

    /// 把错误翻译成用户能懂的话。
    private static func message(for error: EmbyError, address: String) -> String {
        switch error {
        case .invalidURL:
            "地址格式不正确。示例：192.168.1.10:8096 或 https://emby.example.com"
        case .serverUnreachable:
            "无法连接到 \(address)。请确认服务器已启动、地址与端口正确。"
        case .timeout:
            "连接 \(address) 超时。请检查网络或防火墙。"
        case .decoding:
            "\(address) 有响应，但看起来不是 Emby 服务器。"
        case .notFound:
            "\(address) 上找不到 Emby 服务，请检查是否填了子路径（如 /emby）。"
        default:
            String(localized: error.userMessage)
        }
    }
}
