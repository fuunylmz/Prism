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
/// 1. **启动恢复**：从本机存储读回上次的会话，免登录进入主界面；
/// 2. **登录**：`ConnectView` 完成后把会话交进来，持久化并切到主界面；
/// 3. **登出**：清 token、保留服务器记录，退回登录页。
///
/// 为什么单独一个类型：`RootView` 是 SwiftUI 视图，不适合放异步的磁盘读写与网络逻辑；
/// 而且这些状态要在整个 App 生命周期内保持（视图重建不该丢失登录态）。
@MainActor
@Observable
public final class SessionBootstrapper {
    /// 当前阶段。
    public enum Phase: Sendable {
        /// 还在读本机存储（启动瞬间）。
        case restoring
        /// 没有可用会话，需要登录。
        case needsConnection
        /// 已登录。
        case ready(PrismSession)
    }

    /// 当前阶段。
    public private(set) var phase: Phase = .restoring

    /// 已登记的服务器，供主界面的切换器展示。
    public private(set) var availableServers: [ServerConnection] = []

    /// 连接页当前预选的服务器；添加新服务器时为 `nil`。
    public private(set) var pendingConnectionServer: ServerConnection?
    /// 目标服务器最近使用的用户名，重新登录时用于预填。
    public private(set) var pendingConnectionUsername = ""

    /// 进入连接页前的会话，取消时恢复。
    private var sessionBeforeConnection: PrismSession?

    public var canCancelConnection: Bool { sessionBeforeConnection != nil }

    /// 凭据存储（服务器 + 用户名 + 密码）。
    public let store: CredentialStore

    /// 用凭据向服务器换取新会话的实现。
    ///
    /// 默认走真实网络（`EmbyClient.authenticate`）。留这个接缝是因为启动自动登录
    /// **必须能被单测覆盖**：它是「打开 App 直接进主界面」这条路径的核心，
    /// 而单测不能真的连一台 Emby 服务器。
    private let authenticate: @Sendable (ServerConnection, String, String) async throws -> AuthSession
    /// 服务器列表。
    public let registry: ServerRegistry
    /// 恢复/登录的协调者。
    public let restoration: SessionRestoration

    /// 创建引导器。
    ///
    /// - Parameters:
    ///   - store: 凭据存储；默认写到应用容器内的文件。
    ///   - registry: 服务器列表；默认用 `UserDefaults`。
    ///   - authenticate: 用凭据换取会话的实现；默认走真实网络。
    ///     仅供测试注入，业务代码不要传。
    public init(
        store: CredentialStore? = nil,
        registry: ServerRegistry? = nil,
        authenticate: (@Sendable (ServerConnection, String, String) async throws -> AuthSession)? = nil
    ) {
        let resolvedStore = store ?? CredentialStore(secureStore: FileSecureStore())
        let resolvedRegistry = registry ?? ServerRegistry()
        self.store = resolvedStore
        self.registry = resolvedRegistry
        self.restoration = SessionRestoration(store: resolvedStore, registry: resolvedRegistry)
        self.authenticate = authenticate ?? { server, username, password in
            let client = EmbyClient(server: server, identity: ClientIdentity.current())
            return try await client.authenticate(username: username, password: password)
        }
    }

    /// 启动时调用一次。
    ///
    /// 失败（本机存储不可读 / 数据损坏）时退回登录页而不是崩溃——
    /// 用户最多重新登录一次，不该因为一条坏记录打不开 App。
    public func restore() async {
        do {
            availableServers = await registry.servers()
            switch try await restoration.restore() {
            case let .needsRelogin(credential, server):
                // 本机存的是密码而不是 token，所以启动时必须联网换一次新 token。
                await relogin(credential: credential, server: server)
            case let .signedIn(session):
                guard let server = await server(for: session) else {
                    phase = .needsConnection
                    return
                }
                let prismSession = makeSession(server: server, auth: session)
                await prismSession.activate()
                availableServers = await registry.servers()
                phase = .ready(prismSession)
            case .signedOut, .unknown:
                phase = .needsConnection
            }
        } catch {
            phase = .needsConnection
        }
    }

    /// 用本机保存的凭据重新登录。
    ///
    /// 三种结果：
    /// - 成功 → 进入主界面（`phase = .ready`）；
    /// - 密码已失效（401/403）→ 删掉这条凭据，回登录页并预填服务器与用户名；
    /// - 网络不通 → **保留凭据**回登录页，用户联网后可直接重试，不用重输密码。
    ///
    /// 为什么网络失败不删凭据：离线一次就要求重输密码，等于把「记住我」变成摆设。
    ///
    /// - Parameters:
    ///   - credential: 本机保存的凭据。
    ///   - server: 对应的服务器连接信息。
    private func relogin(credential: StoredCredential, server: ServerConnection) async {
        do {
            let auth = try await authenticate(server, credential.username, credential.password)
            // 用户 id 可能与上次不同（服务器重建过账号），以本次为准。
            try? await store.save(
                StoredCredential(
                    serverId: auth.serverId,
                    userId: auth.userId,
                    username: credential.username,
                    password: credential.password,
                    lastSignedInAt: Date()
                )
            )
            await registry.markUsed(id: server.id)

            let prismSession = makeSession(server: server, auth: auth)
            await prismSession.activate()
            availableServers = await registry.servers()
            phase = .ready(prismSession)
        } catch let error as EmbyError {
            switch error {
            case .unauthorized, .forbidden:
                // 密码确实失效了：删掉凭据，避免每次启动都白试一次。
                try? await store.markLoggedOut(serverId: credential.serverId)
                persistenceFailure = "保存的登录信息已失效，请重新登录。"
            default:
                // 网络问题：凭据留着，下次启动或用户手动重试时再用。
                persistenceFailure = "暂时无法连接服务器，稍后会自动重试。"
            }
            phase = .needsConnection
        } catch {
            persistenceFailure = "暂时无法连接服务器，稍后会自动重试。"
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
    ///   - username: 登录用的用户名（随凭据一起保存）。
    ///   - password: 登录用的密码（随凭据一起保存，见 ``StoredCredential`` 的安全说明）。
    ///   - persist: 是否写入本机存储（对应界面上的「记住我」）。
    ///     传 `false` 时本次登录照常可用，只是下次启动要重新登录。
    public func signedIn(
        server: ServerConnection,
        auth: AuthSession,
        username: String,
        password: String,
        persist: Bool = true
    ) async {
        persistenceFailure = nil

        // 服务器地址**无论如何都要登记**：它不含敏感内容，且是「下次不用重打地址」
        // 的前提。早期实现只在「不记住」的分支里登记，一旦本机存储写入失败
        // （沙盒 + ad-hoc 签名下必现），地址和 token 就都没留下，
        // 于是每次启动都是全新的登录页。
        await registry.upsert(server)
        await registry.markUsed(id: server.id)
        availableServers = await registry.servers()

        if persist {
            do {
                try await restoration.signIn(
                    auth,
                    username: username,
                    password: password,
                    server: server
                )
            } catch {
                // 失败不阻断本次使用，但必须让用户知道「下次要重登」。
                persistenceFailure = (error as? SessionStoreError).map(Self.message(for:)) 
                    ?? error.localizedDescription
            }
        }

        let session = makeSession(server: server, auth: auth)
        await session.activate()
        pendingConnectionServer = nil
        pendingConnectionUsername = ""
        sessionBeforeConnection = nil
        phase = .ready(session)
    }

    /// 切换到另一台已登记的服务器。
    ///
    /// 每台服务器使用自己最近一次成功登录的凭据重新认证；认证失败时保留当前会话，
    /// 避免切换失败把用户无故踢回登录页。
    ///
    /// - Parameter serverID: 目标服务器 id。
    /// - Returns: 是否成功切换。
    @discardableResult
    public func switchServer(id serverID: String) async -> Bool {
        guard let target = (await registry.servers()).first(where: { $0.id == serverID }) else {
            persistenceFailure = "找不到要切换的服务器。"
            return false
        }

        guard let credential = await latestCredential(for: serverID) else {
            beginConnection(target: target)
            return false
        }

        do {
            let auth = try await authenticate(target, credential.username, credential.password)
            guard auth.serverId == target.id else {
                persistenceFailure = "服务器身份与保存的记录不匹配。"
                return false
            }
            do {
                try await restoration.signIn(
                    auth,
                    username: credential.username,
                    password: credential.password,
                    server: target
                )
                persistenceFailure = nil
            } catch let error as SessionStoreError {
                // The remote login succeeded; local persistence only affects the next launch.
                persistenceFailure = Self.message(for: error)
            }
            await registry.upsert(target)
            await registry.markUsed(id: target.id)
            availableServers = await registry.servers()
            let session = makeSession(server: target, auth: auth)
            await session.activate()
            phase = .ready(session)
            return true
        } catch let error as EmbyError {
            if error == .unauthorized || error == .forbidden {
                try? await store.markLoggedOut(serverId: serverID)
                beginConnection(target: target, username: credential.username)
                return false
            }
            persistenceFailure = error == .unauthorized || error == .forbidden
                ? "这台服务器的登录信息已失效，请重新登录。"
                : "暂时无法连接这台服务器。"
            return false
        } catch let error as SessionStoreError {
            persistenceFailure = Self.message(for: error)
            return false
        } catch {
            persistenceFailure = "暂时无法连接这台服务器。"
            return false
        }
    }

    /// 已登录状态下启动添加服务器流程。
    public func beginAddingServer() {
        beginConnection(target: nil)
    }

    /// 取消添加 / 重新登录并回到此前会话。
    public func cancelConnection() {
        pendingConnectionServer = nil
        pendingConnectionUsername = ""
        guard let session = sessionBeforeConnection else { return }
        sessionBeforeConnection = nil
        phase = .ready(session)
    }

    private func beginConnection(target: ServerConnection?, username: String = "") {
        if case let .ready(session) = phase {
            sessionBeforeConnection = session
        }
        pendingConnectionServer = target
        pendingConnectionUsername = username
        persistenceFailure = nil
        phase = .needsConnection
    }

    /// 把存储错误翻译成用户能懂的话。
    ///
    /// - Parameter error: 会话存储错误。
    /// - Returns: 提示文案。
    private static func message(for error: SessionStoreError) -> String {
        switch error {
        case let .file(code, operation):
            "本机存储不可用（\(operation.rawValue) 失败，错误码 \(code)），本次登录不会被记住。"
        case let .encoding(detail):
            "登录信息编码失败：\(detail)"
        case let .decoding(detail):
            "登录信息格式不兼容：\(detail)"
        case let .invalidValue(detail):
            "登录信息不完整：\(detail)"
        case let .sessionNotFound(serverId, userId):
            "找不到保存的登录信息（\(serverId) / \(userId)）。"
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
        return servers.first { $0.id == auth.serverId }
    }

    private func latestCredential(for serverID: String) async -> StoredCredential? {
        let credentials = (try? await store.loadAll())?.filter {
            $0.serverId == serverID && $0.isUsable
        } ?? []
        return credentials.enumerated().max { lhs, rhs in
            switch (lhs.element.lastSignedInAt, rhs.element.lastSignedInAt) {
            case let (left?, right?): return left == right ? lhs.offset < rhs.offset : left < right
            case (nil, nil): return lhs.offset < rhs.offset
            case (nil, _?): return true
            case (_?, nil): return false
            }
        }?.element
    }

    private func makeSession(server: ServerConnection, auth: AuthSession) -> PrismSession {
        PrismSession(server: server, session: auth)
    }
}
