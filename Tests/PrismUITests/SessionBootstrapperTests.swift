import Foundation
import Testing
import PrismCore
import PrismData
@testable import PrismUI

/// ``SessionBootstrapper`` 的持久化行为。
///
/// 守的是一条真实故障（用户反馈「每次打开都要重新输入服务器」）：
/// 沙盒 + ad-hoc 签名下数据保护钥匙串返回 `-34018`（缺 entitlement），
/// 会话写不进去；而当时 `signedIn` 用 `try?` 吞掉错误，
/// **并且只在「不记住」分支登记服务器地址**——结果地址和 token 都没留下，
/// 每次启动都是全新的登录页。
@Suite("SessionBootstrapper 持久化")
@MainActor
struct SessionBootstrapperTests {
    // MARK: 夹具

    /// 永远失败的存储：模拟「钥匙串缺 entitlement」。
    private final class FailingSecureStore: SecureStoring, @unchecked Sendable {
        func save(_ data: Data, account: String, service: String) throws {
            throw SessionStoreError.file(code: 513, operation: .write)
        }

        func load(account: String, service: String) throws -> Data? { nil }

        func delete(account: String, service: String) throws {}

        func deleteAll(service: String) throws {}
    }

    private final class ToggleFailingSecureStore: SecureStoring, @unchecked Sendable {
        private let lock = NSLock()
        private let backing = InMemorySecureStore()
        private var _failsWrites = false

        var failsWrites: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return _failsWrites
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                _failsWrites = newValue
            }
        }

        func save(_ data: Data, account: String, service: String) throws {
            if failsWrites {
                throw SessionStoreError.file(code: 513, operation: .write)
            }
            try backing.save(data, account: account, service: service)
        }

        func load(account: String, service: String) throws -> Data? {
            try backing.load(account: account, service: service)
        }

        func delete(account: String, service: String) throws {
            try backing.delete(account: account, service: service)
        }

        func deleteAll(service: String) throws {
            try backing.deleteAll(service: service)
        }
    }

    /// 在**非隔离**上下文里造一个服务器注册表。
    ///
    /// `UserDefaults` 不是 `Sendable`，而本套件是 `@MainActor`（`SessionBootstrapper`
    /// 就在主线程上）。直接把主线程创建的实例交给 `ServerRegistry` actor 会被
    /// 严格并发拦下，因此这里用 `nonisolated` 工厂在调用方隔离域之外创建。
    private nonisolated static func makeRegistry(suiteName: String) throws -> ServerRegistry {
        ServerRegistry(defaults: try #require(UserDefaults(suiteName: suiteName)))
    }

    /// 造一个不联网的登录实现：直接返回预设会话。
    ///
    /// - Parameter server: 用于构造会话的服务器。
    /// - Returns: 登录闭包。
    private static func stubAuth(server: ServerConnection) -> @Sendable (ServerConnection, String, String) async throws -> AuthSession {
        { _, username, _ in
            AuthSession(
                serverId: server.id,
                userId: "user-1",
                accessToken: "fresh-token",
                user: EmbyUser(id: "user-1", name: username, serverId: server.id)
            )
        }
    }

    private func makeFixture(
        failing: Bool,
        authenticate: (@Sendable (ServerConnection, String, String) async throws -> AuthSession)? = nil
    ) throws -> (SessionBootstrapper, ServerRegistry, String) {
        let suiteName = "test.prism.bootstrap.\(UUID().uuidString)"
        let registry = try Self.makeRegistry(suiteName: suiteName)
        let secure: any SecureStoring = failing ? FailingSecureStore() : InMemorySecureStore()
        let store = CredentialStore(secureStore: secure)
        let bootstrapper = SessionBootstrapper(store: store, registry: registry, authenticate: authenticate)
        return (bootstrapper, registry, suiteName)
    }

    private func makeServer() throws -> ServerConnection {
        ServerConnection(
            id: "srv-media",
            name: "media.micu.hk",
            baseURL: try #require(URL(string: "https://media.micu.hk"))
        )
    }

    private func makeAuthSession(serverId: String = "srv-media") -> AuthSession {
        AuthSession(
            serverId: serverId,
            userId: "user-1",
            accessToken: "token-abc",
            user: EmbyUser(id: "user-1", name: "小林", serverId: serverId)
        )
    }

    // MARK: 关键回归

    @Test("即使会话写不进钥匙串，服务器地址也必须留下")
    func serverIsRegisteredEvenWhenPersistenceFails() async throws {
        let (bootstrapper, registry, suite) = try makeFixture(failing: true)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let server = try makeServer()

        await bootstrapper.signedIn(server: server, auth: makeAuthSession(), username: "小林", password: "pw", persist: true)

        // 地址必须还在：这是「下次不用重打地址」的唯一前提。
        let saved = await registry.servers()
        #expect(saved.count == 1)
        #expect(saved.first?.id == "srv-media")
        #expect(saved.first?.baseURL.absoluteString == "https://media.micu.hk")
        #expect(await registry.lastActiveServerId == "srv-media")
    }

    @Test("会话写不进去时，明确记录失败原因而不是静默吞掉")
    func persistenceFailureIsReported() async throws {
        let (bootstrapper, _, suite) = try makeFixture(failing: true)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        await bootstrapper.signedIn(server: try makeServer(), auth: makeAuthSession(), username: "小林", password: "pw", persist: true)

        let message = try #require(bootstrapper.persistenceFailure)
        #expect(message.contains("513"))
        // 登录本身仍然是成功的：用户这一轮可以正常用。
        if case .ready = bootstrapper.phase {} else {
            Issue.record("持久化失败不该阻断本次登录")
        }
    }

    @Test("正常存储时不留失败标记，并且重启能免登录恢复")
    func successfulPersistenceRestoresOnNextLaunch() async throws {
        let suite = "test.prism.bootstrap.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let secure = InMemorySecureStore()
        let store = CredentialStore(secureStore: secure)
        let registry = try Self.makeRegistry(suiteName: suite)
        let server = try makeServer()

        let stub = Self.stubAuth(server: server)

        let first = SessionBootstrapper(store: store, registry: registry, authenticate: stub)
        await first.signedIn(server: server, auth: makeAuthSession(), username: "小林", password: "pw", persist: true)
        #expect(first.persistenceFailure == nil)

        // 模拟重启：同一份存储与 UserDefaults，新的引导器。
        // 注意：这里必须注入桩，否则会真的去连 192.168.1.10。
        let second = SessionBootstrapper(store: store, registry: registry, authenticate: stub)
        await second.restore()

        guard case let .ready(session) = second.phase else {
            Issue.record("应当免登录恢复到主界面，实际停留在 \(second.phase)")
            return
        }
        #expect(session.server.id == "srv-media")
        #expect(session.userId == "user-1")
        #expect(session.accessToken == "fresh-token")
    }

    @Test("没有会话时恢复结果是「需要连接」，不会误判为已登录")
    func restoreWithoutSessionNeedsConnection() async throws {
        let (bootstrapper, _, suite) = try makeFixture(failing: false)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        await bootstrapper.restore()

        if case .needsConnection = bootstrapper.phase {} else {
            Issue.record("空存储应当回到登录页")
        }
    }

    // MARK: 自动重新登录的结果分支

    @Test("密码已失效：删掉凭据并回到登录页，避免每次启动白试一次")
    func expiredPasswordDropsCredential() async throws {
        let server = try makeServer()
        let suite = "test.prism.bootstrap.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let secure = InMemorySecureStore()
        let store = CredentialStore(secureStore: secure)
        let registry = try Self.makeRegistry(suiteName: suite)

        // 先登录成功一次，把凭据存下来。
        let stub = Self.stubAuth(server: server)
        let first = SessionBootstrapper(store: store, registry: registry, authenticate: stub)
        await first.signedIn(server: server, auth: makeAuthSession(), username: "小林", password: "pw", persist: true)

        // 重启时服务器返回 401。
        let second = SessionBootstrapper(
            store: store,
            registry: registry,
            authenticate: { _, _, _ in throw EmbyError.unauthorized }
        )
        await second.restore()

        if case .needsConnection = second.phase {} else {
            Issue.record("应当回到登录页")
        }
        // 凭据必须删掉：留着只会每次启动都白试一次。
        #expect(try await store.loadAll().isEmpty)
        // 但服务器地址仍在，登录页能一键选回。
        #expect(await registry.servers().count == 1)
        #expect(second.persistenceFailure?.contains("失效") == true)
    }

    @Test("网络不通：保留凭据，联网后无需重输密码")
    func networkFailureKeepsCredential() async throws {
        let server = try makeServer()
        let suite = "test.prism.bootstrap.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let secure = InMemorySecureStore()
        let store = CredentialStore(secureStore: secure)
        let registry = try Self.makeRegistry(suiteName: suite)

        let stub = Self.stubAuth(server: server)
        let first = SessionBootstrapper(store: store, registry: registry, authenticate: stub)
        await first.signedIn(server: server, auth: makeAuthSession(), username: "小林", password: "pw", persist: true)

        // 重启时网络不通。
        let second = SessionBootstrapper(
            store: store,
            registry: registry,
            authenticate: { _, _, _ in throw EmbyError.serverUnreachable("offline") }
        )
        await second.restore()

        if case .needsConnection = second.phase {} else {
            Issue.record("离线时应当回到登录页")
        }
        // 关键：离线一次不该把「记住我」作废。
        #expect(try await store.loadAll().count == 1)
        #expect(second.persistenceFailure?.contains("无法连接") == true)
    }

    @Test("不记住登录时：地址留下、token 不写")
    func rememberMeFalseKeepsAddressOnly() async throws {
        let (bootstrapper, registry, suite) = try makeFixture(failing: false)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let server = try makeServer()

        await bootstrapper.signedIn(server: server, auth: makeAuthSession(), username: "小林", password: "pw", persist: false)

        // 地址留下，方便下次直接点选。
        #expect(await registry.servers().count == 1)
        // 但没有 token：下次必须重新输密码。
        #expect(try await bootstrapper.store.loadAll().isEmpty)
    }

    @Test("切换服务器后更新运行时会话和重启默认服务器")
    func switchingServerReauthenticatesAndUpdatesActiveCredential() async throws {
        let suite = "test.prism.bootstrap.switch.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = CredentialStore(secureStore: InMemorySecureStore())
        let registry = try Self.makeRegistry(suiteName: suite)
        let first = try makeServer()
        let second = ServerConnection(
            id: "srv-second",
            name: "书房 Emby",
            baseURL: try #require(URL(string: "https://study.example.com"))
        )
        let bootstrapper = SessionBootstrapper(
            store: store,
            registry: registry,
            authenticate: { server, username, _ in
                AuthSession(
                    serverId: server.id,
                    userId: "user-\(server.id)",
                    accessToken: "token-\(server.id)",
                    user: EmbyUser(id: "user-\(server.id)", name: username, serverId: server.id)
                )
            }
        )

        await bootstrapper.signedIn(
            server: first,
            auth: AuthSession(
                serverId: first.id,
                userId: "user-first",
                accessToken: "token-first",
                user: EmbyUser(id: "user-first", name: "Alice", serverId: first.id)
            ),
            username: "alice",
            password: "first-password"
        )
        await registry.upsert(second)
        try await store.save(StoredCredential(
            serverId: second.id,
            userId: "old-user",
            username: "bob",
            password: "second-password",
            lastSignedInAt: Date()
        ))

        #expect(await bootstrapper.switchServer(id: second.id))
        guard case let .ready(session) = bootstrapper.phase else {
            Issue.record("成功切换后应进入目标服务器会话")
            return
        }
        #expect(session.server.id == second.id)
        #expect(session.session.accessToken == "token-\(second.id)")
        #expect(try await store.active()?.serverId == second.id)
        #expect(await registry.lastActiveServerId == second.id)
        #expect(try await store.credential(serverId: second.id, userId: "user-\(second.id)")?.username == "bob")
    }

    @Test("远端认证成功但本地保存失败时仍切换当前会话")
    func switchingServerContinuesWhenPersistenceFails() async throws {
        let suite = "test.prism.bootstrap.switch-persistence-failure.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let first = try makeServer()
        let second = ServerConnection(
            id: "srv-persistence-failure",
            name: "备用 Emby",
            baseURL: try #require(URL(string: "https://backup.example.com"))
        )
        let secure = ToggleFailingSecureStore()
        let store = CredentialStore(secureStore: secure)
        let registry = try Self.makeRegistry(suiteName: suite)
        let bootstrapper = SessionBootstrapper(
            store: store,
            registry: registry,
            authenticate: { server, username, _ in
                AuthSession(
                    serverId: server.id,
                    userId: "user-\(server.id)",
                    accessToken: "token-\(server.id)",
                    user: EmbyUser(id: "user-\(server.id)", name: username, serverId: server.id)
                )
            }
        )

        await bootstrapper.signedIn(
            server: first,
            auth: makeAuthSession(),
            username: "alice",
            password: "first-password"
        )
        await registry.upsert(second)
        try await store.save(StoredCredential(
            serverId: second.id,
            userId: "old-user",
            username: "bob",
            password: "second-password",
            lastSignedInAt: Date()
        ))
        secure.failsWrites = true

        #expect(await bootstrapper.switchServer(id: second.id))
        guard case let .ready(session) = bootstrapper.phase else {
            Issue.record("本地保存失败时本次已认证会话仍应可用")
            return
        }
        #expect(session.server.id == second.id)
        #expect(session.session.accessToken == "token-\(second.id)")
        #expect(bootstrapper.persistenceFailure?.contains("513") == true)
        #expect(await registry.lastActiveServerId == second.id)
    }

    @Test("目标服务器认证失败时保留当前会话")
    func failedSwitchKeepsCurrentSession() async throws {
        let suite = "test.prism.bootstrap.switch-failure.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let first = try makeServer()
        let second = ServerConnection(
            id: "srv-offline",
            name: "离线 Emby",
            baseURL: try #require(URL(string: "https://offline.example.com"))
        )
        let store = CredentialStore(secureStore: InMemorySecureStore())
        let registry = try Self.makeRegistry(suiteName: suite)
        let bootstrapper = SessionBootstrapper(
            store: store,
            registry: registry,
            authenticate: { server, _, _ in
                if server.id == second.id { throw EmbyError.serverUnreachable("offline") }
                return AuthSession(
                    serverId: server.id,
                    userId: "user-\(server.id)",
                    accessToken: "token-\(server.id)",
                    user: EmbyUser(id: "user-\(server.id)", name: "Alice", serverId: server.id)
                )
            }
        )

        await bootstrapper.signedIn(
            server: first,
            auth: makeAuthSession(),
            username: "alice",
            password: "first-password"
        )
        await registry.upsert(second)
        try await store.save(StoredCredential(
            serverId: second.id,
            userId: "user-offline",
            username: "bob",
            password: "second-password"
        ))

        #expect(await bootstrapper.switchServer(id: second.id) == false)
        guard case let .ready(session) = bootstrapper.phase else {
            Issue.record("切换失败时应保留当前会话")
            return
        }
        #expect(session.server.id == first.id)
        #expect(bootstrapper.persistenceFailure?.contains("无法连接") == true)
    }

    @Test("没有目标凭据时预选服务器登录，取消后恢复当前会话")
    func missingCredentialOpensTargetLoginAndCanReturn() async throws {
        let suite = "test.prism.bootstrap.switch-login.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let first = try makeServer()
        let second = ServerConnection(
            id: "srv-new",
            name: "新服务器",
            baseURL: try #require(URL(string: "https://new.example.com"))
        )
        let registry = try Self.makeRegistry(suiteName: suite)
        let bootstrapper = SessionBootstrapper(
            store: CredentialStore(secureStore: InMemorySecureStore()),
            registry: registry,
            authenticate: Self.stubAuth(server: first)
        )
        await bootstrapper.signedIn(
            server: first,
            auth: makeAuthSession(),
            username: "alice",
            password: "first-password"
        )
        await registry.upsert(second)

        #expect(await bootstrapper.switchServer(id: second.id) == false)
        if case .needsConnection = bootstrapper.phase {} else {
            Issue.record("无凭据的目标服务器应进入连接流程")
        }
        #expect(bootstrapper.pendingConnectionServer?.id == second.id)
        #expect(bootstrapper.canCancelConnection)

        bootstrapper.cancelConnection()
        guard case let .ready(session) = bootstrapper.phase else {
            Issue.record("取消登录后应恢复原会话")
            return
        }
        #expect(session.server.id == first.id)
    }
}
