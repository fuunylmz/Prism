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
}

/// 启动恢复流程：把 ``ServerRegistry``（地址、名称）与 ``SessionStore``（token）拼起来。
///
/// 职责边界：
/// - ``SessionStore`` 只管 token 的存取，不知道服务器地址；
/// - ``ServerRegistry`` 只管地址/名称，不知道 token；
/// - 本类型负责「启动时该显示登录页还是主页」以及「401 之后该清什么、不该清什么」。
///
/// 之所以做成独立的 `struct` 而不是把逻辑塞进 `SessionStore`：恢复流程需要同时协调两个
/// 存储，而 ``SessionStore`` 的职责应该保持单一（`docs/ARCHITECTURE.md` §4 的契约也只
/// 承诺会话本身）。这样 UI 层只依赖一个入口，测试也能各自替换。
///
/// `Sendable`：两个属性都是 actor，天然 `Sendable`。
public struct SessionRestoration: Sendable {
    /// 会话存储。
    public let store: SessionStore
    /// 服务器列表。
    public let registry: ServerRegistry

    /// 创建恢复器。
    ///
    /// - Parameters:
    ///   - store: 会话存储。
    ///   - registry: 服务器列表。
    public init(store: SessionStore, registry: ServerRegistry) {
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
    /// - Throws: ``SessionStoreError``（Keychain 不可读 / 数据损坏）。
    public func restore() async throws -> SessionState {
        let servers = await registry.servers()

        guard let session = try await store.active(), session.isValid else {
            return .signedOut
        }

        // 顺手把「上次激活的服务器」校正成实际恢复出来的那台：
        // 会话是权威来源，registry 里的只是一个 UI 预选提示。只在该服务器确实登记过时
        // 才写，避免留下一个指向不存在服务器的悬空 id。
        if servers.contains(where: { $0.id == session.serverId }) {
            let hinted = await registry.lastActiveServerId
            if hinted != session.serverId {
                await registry.setLastActiveServerId(session.serverId)
            }
        }

        return .signedIn(session)
    }

    /// 登录成功后调用：保存会话、设为 active，并登记/刷新服务器记录。
    ///
    /// - Parameters:
    ///   - session: 登录得到的会话。
    ///   - server: 对应的服务器连接信息；传 `nil` 表示调用方自己维护 registry
    ///     （例如 Demo Mode 或测试）。
    /// - Throws: ``SessionStoreError``。
    public func signIn(_ session: AuthSession, server: ServerConnection? = nil) async throws {
        try await store.save(session)
        try await store.setActive(serverId: session.serverId, userId: session.userId)

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
