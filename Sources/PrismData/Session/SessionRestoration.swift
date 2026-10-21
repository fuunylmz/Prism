import Foundation
import PrismCore

/// 应用启动时的登录态。
///
/// `unknown` 是「还没查完」的初始态，给 UI 留一个不闪登录页的空档；
/// 恢复流程结束后只会落到 `signedOut` 或 `signedIn`。
public enum SessionState: Sendable, Equatable {
    /// 尚未完成恢复（启动瞬间）。
    case unknown
    /// 没有可用会话，需要登录。
    case signedOut
    /// 已恢复登录态。
    case signedIn(AuthSession)
    /// 本机有可用凭据，但需要先向服务器换取新 token。
    ///
    /// 为什么单列一态：客户端存的是用户名 + 密码而不是 token，启动时必须**联网**
    /// 重新登录一次才能拿到 `AuthSession`。这一步是异步的，UI 需要显示「正在恢复登录」
    /// 而不是闪一下登录页。拿到会话后由调用方把状态推进到 ``signedIn(_:)``。
    case needsRelogin(StoredCredential, ServerConnection)
}

/// 启动恢复流程：把 ``ServerRegistry``（地址、名称）与 ``CredentialStore``（用户名 + 密码）拼起来。
///
/// 职责边界：
/// - ``CredentialStore`` 只管凭据的存取，不知道服务器地址；
/// - ``ServerRegistry`` 只管地址/名称，不知道凭据；
/// - 本类型负责「启动时该显示登录页还是主页」以及「401 之后该清什么、不该清什么」。
///
/// 之所以做成独立的 `struct` 而不是把逻辑塞进 `SessionStore`：恢复流程需要同时协调两个
/// 存储，而 ``SessionStore`` 的职责应该保持单一（`docs/ARCHITECTURE.md` §4 的契约也只
/// 承诺会话本身）。这样 UI 层只依赖一个入口，测试也能各自替换。
///
/// `Sendable`：两个属性都是 actor，天然 `Sendable`。
public struct SessionRestoration: Sendable {
    /// 凭据存储。
    public let store: CredentialStore
    /// 服务器列表。
    public let registry: ServerRegistry

    /// 创建恢复器。
    ///
    /// - Parameters:
    ///   - store: 凭据存储。
    ///   - registry: 服务器列表。
    public init(store: CredentialStore, registry: ServerRegistry) {
        self.store = store
        self.registry = registry
    }

    /// 执行启动恢复。
    ///
    /// 流程：
    /// 1. 读服务器列表（不含敏感信息，随时可读）。
    /// 2. 取 ``SessionStore/active()``，即上次使用的会话。
    /// 3. 会话存在**且令牌非空**（``AuthSession/isValid``）→ ``SessionState/signedIn(_:)``；
    ///    否则 ``SessionState/signedOut``。
    ///
    /// 两个刻意的取舍：
    /// - **令牌为空也算未登录**。历史数据里可能留下 `AccessToken == ""` 的会话
    ///   （解码兜底会产生），它不可能通过任何鉴权，直接当未登录处理，避免 UI 进去后
    ///   立刻被 401 弹回。
    /// - **服务器记录缺失不影响已登录判定**。token 有效就够了；地址只是展示信息，
    ///   丢了不该把用户踢回登录页（真缺地址时 UI 可用 `session.serverId` 反查或提示重填）。
    ///
    /// - Returns: 恢复出的状态。
    /// - Throws: ``SessionStoreError``（本机存储不可读 / 数据损坏）。
    public func restore() async throws -> SessionState {
        let servers = await registry.servers()

        guard let credential = try await store.active(), credential.isUsable else {
            return .signedOut
        }

        // 服务器记录缺失就没法登录：地址是发请求的前提，凭据本身不含地址。
        // 这里不退化成「让用户重填」，而是明确返回未登录——上层会展示登录页，
        // 并从 registry 里列出已知服务器供一键选择。
        guard let server = servers.first(where: { $0.id == credential.serverId }) else {
            return .signedOut
        }

        // 顺手把「上次激活的服务器」校正成实际凭据所在的那台：
        // 凭据是权威来源，registry 里的只是一个 UI 预选提示。
        if await registry.lastActiveServerId != server.id {
            await registry.setLastActiveServerId(server.id)
        }

        return .needsRelogin(credential, server)
    }

    /// 登录成功后调用：保存会话、设为 active，并登记/刷新服务器记录。
    ///
    /// - Parameters:
    ///   - session: 登录得到的会话。
    ///   - server: 对应的服务器连接信息；传 `nil` 表示调用方自己维护 registry
    ///     （例如 Demo Mode 或测试）。
    /// - Throws: ``SessionStoreError``。
    public func signIn(
        _ session: AuthSession,
        username: String,
        password: String,
        server: ServerConnection? = nil
    ) async throws {
        let credential = StoredCredential(
            serverId: session.serverId,
            userId: session.userId,
            username: username,
            password: password,
            lastSignedInAt: Date()
        )
        try await store.save(credential)
        try await store.setActive(serverId: session.serverId, userId: session.userId)
        await store.removeLegacyTokenFile()

        if let server {
            await registry.upsert(server)
            await registry.markUsed(id: server.id)
        }
    }

    /// token 失效（HTTP 401 / 被服务器吊销）的处理入口。
    ///
    /// **清 token，保留服务器记录**：只删 ``SessionStore`` 里该服务器的会话，
    /// ``ServerRegistry`` 完全不动——地址、名称、`lastActiveServerId` 都还在，
    /// 用户重新登录时只需输密码，不用重新填地址。
    ///
    /// - Parameter serverId: 服务器 id。
    /// - Throws: ``SessionStoreError``。
    public func invalidate(serverId: String) async throws {
        try await store.markLoggedOut(serverId: serverId)
        // 注意：这里刻意不碰 registry。改这一行之前请先读上面的文档注释。
    }

    /// 已知的服务器列表（最近使用优先），供登录页/服务器切换器直接展示。
    ///
    /// - Returns: 服务器数组。
    public func knownServers() async -> [ServerConnection] {
        await registry.servers()
    }
}

// MARK: - 校验已恢复的会话

/// 恢复出的会话是否仍然有效（token 有没有被服务器吊销）。
///
/// **为什么需要单独一步**：``SessionRestoration/restore()`` 只读本地存储、不联网，
/// 所以启动是「秒开」的；但 token 可能已在服务器端被吊销（改密码、管理员踢人、重装服务器）。
/// 是否联网校验、什么时候校验，由 UI 层决定（也可以延后到首个请求 401 时）。
///
/// **端点选择（重要）**：`/Users/Me` 是 **Jellyfin** 的端点，**Emby 没有**
/// （Emby OpenAPI 的 32 条 `/Users` 路径里不含它，Reference 页 404；
/// 详见 `docs/ARCHITECTURE.md` §2.2 的核实记录）。所以顺序必须是：
///
/// 1. 本地有 `userId` → 先 `GET /Users/{Id}`（Emby 支持）
/// 2. 404 → 回退 `GET /Users/Me`（兼容 Jellyfin）
/// 3. 401 → 判定 token 失效，清 token、**保留服务器记录**
///
/// 为了可测，取用户的能力用两个闭包注入，而不是直接依赖 `EmbyClient`。
public struct SessionValidator: Sendable {
    private let fetchUserById: @Sendable (String) async throws -> EmbyUser
    private let fetchCurrentUser: @Sendable () async throws -> EmbyUser
    private let restoration: SessionRestoration

    /// 创建校验器。
    ///
    /// - Parameters:
    ///   - fetchUserById: `GET /Users/{Id}`，通常传 `{ try await client.user(id: $0) }`。
    ///   - fetchCurrentUser: `GET /Users/Me`，通常传 `{ try await client.currentUser() }`。
    ///   - restoration: token 失效时用于清理本地状态。
    public init(
        fetchUserById: @escaping @Sendable (String) async throws -> EmbyUser,
        fetchCurrentUser: @escaping @Sendable () async throws -> EmbyUser,
        restoration: SessionRestoration
    ) {
        self.fetchUserById = fetchUserById
        self.fetchCurrentUser = fetchCurrentUser
        self.restoration = restoration
    }

    /// 校验一个已恢复的会话。
    ///
    /// - Parameter session: 从本地恢复出的会话。
    /// - Returns: 校验通过时返回**服务器最新**的用户对象（可能改过名/头像）；
    ///   token 失效返回 `nil`，且已清掉本地 token（服务器记录保留）。
    /// - Throws: 网络错误（超时/不可达）**原样抛出**——离线时不应把用户登出。
    public func validate(_ session: AuthSession) async throws -> EmbyUser? {
        do {
            return try await fetchUserById(session.userId)
        } catch let error as EmbyError {
            switch error {
            case .notFound:
                // userId 在服务器上不存在（用户被删/换了服务器）→ 试 /Users/Me。
                return try await fallbackToCurrentUser(session: session)
            case .unauthorized:
                try await restoration.invalidate(serverId: session.serverId)
                return nil
            default:
                // 超时 / 服务器不可达：交给调用方决定是否离线放行。
                throw error
            }
        }
    }

    private func fallbackToCurrentUser(session: AuthSession) async throws -> EmbyUser? {
        do {
            return try await fetchCurrentUser()
        } catch let error as EmbyError {
            switch error {
            case .unauthorized, .notFound:
                // 两个端点都不可用 → 视为失效。
                try await restoration.invalidate(serverId: session.serverId)
                return nil
            default:
                throw error
            }
        }
    }
}
