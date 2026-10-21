import Foundation
import Observation
import PrismCore
import EmbyAPI
import PrismData
import SwiftUI

// MARK: - 启动引导

/// 决定 App 启动后该显示什么：登录页、还是主界面。
///
/// 职责：
/// 1. **启动恢复**：从 Keychain 读回上次的会话，免登录进入主界面；
/// 2. **登录**：`ConnectView` 完成后把会话交进来，持久化并切到主界面；
/// 3. **登出**：清 token、保留服务器记录，退回登录页。
///
/// 为什么单独一个类型：`RootView` 是 SwiftUI 视图，不适合放异步的 Keychain 与网络逻辑；
/// 而且这些状态要在整个 App 生命周期内保持（视图重建不该丢失登录态）。
@MainActor
@Observable
public final class SessionBootstrapper {
    /// 当前阶段。
    public enum Phase: Sendable {
        /// 还在读 Keychain（启动瞬间）。
        case restoring
        /// 没有可用会话，需要登录。
        case needsConnection
        /// 已登录。
        case ready(PrismSession)
    }

    /// 当前阶段。
    public private(set) var phase: Phase = .restoring

    /// 会话存储。
    public let store: SessionStore
    /// 服务器列表。
    public let registry: ServerRegistry
    /// 恢复/登录的协调者。
    public let restoration: SessionRestoration

    /// 创建引导器。
    ///
    /// - Parameters:
    ///   - store: 会话存储；默认用真实 Keychain。
    ///   - registry: 服务器列表；默认用 `UserDefaults`。
    public init(
        store: SessionStore? = nil,
        registry: ServerRegistry? = nil
    ) {
        let resolvedStore = store ?? SessionStore(secureStore: KeychainSecureStore())
        let resolvedRegistry = registry ?? ServerRegistry()
        self.store = resolvedStore
        self.registry = resolvedRegistry
        self.restoration = SessionRestoration(store: resolvedStore, registry: resolvedRegistry)
    }

    /// 启动时调用一次。
    ///
    /// 失败（Keychain 不可读 / 数据损坏）时退回登录页而不是崩溃——
    /// 用户最多重新登录一次，不该因为一条坏记录打不开 App。
    public func restore() async {
        do {
            switch try await restoration.restore() {
            case let .signedIn(session):
                guard let server = await server(for: session) else {
                    // 有 token 但没有服务器地址：地址是展示信息，缺了没法发请求，
                    // 只能让用户重填。token 留着，重连同一服务器时还能复用。
                    phase = .needsConnection
                    return
                }
                let prismSession = makeSession(server: server, auth: session)
                await prismSession.activate()
                phase = .ready(prismSession)
            case .signedOut, .unknown:
                phase = .needsConnection
            }
        } catch {
            phase = .needsConnection
        }
    }

    /// 上次持久化是否失败；`nil` 表示没失败过。
    ///
    /// 用途：登录后如果会话没能写进本机存储，界面要**明确告诉用户**
    /// 「本次登录不会被记住」，而不是静默吞掉、让用户下次打开时困惑
    /// 「为什么又要输一遍」。这正是之前「每次打开都要重新输入服务器」的成因之一。
    public private(set) var persistenceFailure: String?

    /// 登录成功后由 `ConnectView` 调用。
    ///
    /// - Parameters:
    ///   - server: 服务器连接信息。
    ///   - auth: 登录得到的会话。
    ///   - persist: 是否写入本机存储（对应界面上的「记住我」）。
    ///     传 `false` 时本次登录照常可用，只是下次启动要重新登录。
    public func signedIn(
        server: ServerConnection,
        auth: AuthSession,
        persist: Bool = true
    ) async {
        persistenceFailure = nil

        // 服务器地址**无论如何都要登记**：它不含敏感内容，且是「下次不用重打地址」
        // 的前提。早期实现只在「不记住」的分支里登记，一旦 Keychain 写入失败
        // （沙盒 + ad-hoc 签名下必现），地址和 token 就都没留下，
        // 于是每次启动都是全新的登录页。
        await registry.upsert(server)
        await registry.markUsed(id: server.id)

        if persist {
            do {
                try await restoration.signIn(auth, server: server)
            } catch {
                // 失败不阻断本次使用，但必须让用户知道「下次要重登」。
                persistenceFailure = (error as? SessionStoreError).map(Self.message(for:)) 
                    ?? error.localizedDescription
            }
        }

        let session = makeSession(server: server, auth: auth)
        await session.activate()
        phase = .ready(session)
    }

    /// 把存储错误翻译成用户能懂的话。
    ///
    /// - Parameter error: 会话存储错误。
    /// - Returns: 提示文案。
    private static func message(for error: SessionStoreError) -> String {
        switch error {
        case let .keychain(status, operation):
            "本机存储不可用（钥匙串 \(operation.rawValue) 返回 \(status)），本次登录不会被记住。"
        case let .encoding(detail):
            "会话数据编码失败：\(detail)"
        case let .decoding(detail):
            "会话数据格式不兼容：\(detail)"
        case let .invalidValue(detail):
            "会话参数不合法：\(detail)"
        case let .sessionNotFound(serverId, userId):
            "找不到会话（\(serverId) / \(userId)）。"
        }
    }

    /// 从同步上下文（菜单 / 侧边栏按钮）发起登出。
    ///
    /// `NavigationModel.onSignOut` 是同步闭包，这里转成任务执行异步清理；
    /// 不等待结果，`phase` 变化后 SwiftUI 会自动切回登录页。
    public func requestSignOut() {
        Task { await signOut() }
    }

    /// 登出：清 token、保留服务器记录，退回登录页。
    public func signOut() async {
        if case let .ready(session) = phase {
            try? await restoration.invalidate(serverId: session.server.id)
        }
        phase = .needsConnection
    }

    // MARK: 内部

    private func server(for auth: AuthSession) async -> ServerConnection? {
        let servers = await registry.servers()
        return servers.first { $0.id == auth.serverId } ?? servers.first
    }

    private func makeSession(server: ServerConnection, auth: AuthSession) -> PrismSession {
        PrismSession(server: server, session: auth)
    }
}
