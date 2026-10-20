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
                phase = .ready(makeSession(server: server, auth: session))
            case .signedOut, .unknown:
                phase = .needsConnection
            }
        } catch {
            phase = .needsConnection
        }
    }

    /// 登录成功后由 `ConnectView` 调用。
    ///
    /// - Parameters:
    ///   - server: 服务器连接信息。
    ///   - auth: 登录得到的会话。
    ///   - persist: 是否写入 Keychain（对应界面上的「记住我」）。
    ///     传 `false` 时本次登录照常可用，只是下次启动要重新登录。
    public func signedIn(
        server: ServerConnection,
        auth: AuthSession,
        persist: Bool = true
    ) async {
        if persist {
            // 持久化失败不阻断本次使用：用户这一轮能正常用，
            // 下次启动再登录一次即可。
            try? await restoration.signIn(auth, server: server)
        } else {
            // 不记住：只把服务器地址留在列表里（下次不用重填地址），
            // 但**不写 token**。
            await registry.upsert(server)
            await registry.markUsed(id: server.id)
        }

        let session = makeSession(server: server, auth: auth)
        await session.activate()
        phase = .ready(session)
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
