import Foundation
import Testing
import PrismCore
@testable import PrismData

/// ``SessionValidator``：校验「从本地恢复出的会话，其 token 是否仍被服务器认可」。
///
/// 全部用例都通过闭包注入伪造的 `GET /Users/{Id}` 与 `GET /Users/Me`，**不发任何真实网络请求**；
/// Keychain 用 ``InMemorySecureStore``，`UserDefaults` 用一次性 suite 并在结束时清理。
///
/// 这里守的核心契约是两条，任何一条被改坏都会造成真实的用户可见故障：
///
/// 1. **成功路径只打一个端点**。`/Users/Me` 是 Jellyfin 的端点，Emby 没有它，
///    所以「每次都打两个端点」在 Emby 上会稳定失败。
/// 2. **只有 401 才清 token**。超时 / 不可达必须原样抛出——离线时把用户登出，
///    等于让用户在没有网络的飞机上丢掉登录态。
@Suite("SessionValidator", .serialized)
struct SessionValidatorTests {
    // MARK: - 夹具

    /// 伪造端点的预设结果。
    private enum StubOutcome: Sendable {
        /// 返回这个用户。
        case success(EmbyUser)
        /// 抛出这个错误。
        case failure(EmbyError)
    }

    /// 伪造的 Emby 端点：记录「被调了几次、传了什么参数」，按预设结果返回或抛错。
    ///
    /// 用 `actor` 而不是加锁的 `class`：`SessionValidator` 的闭包是 `@Sendable`，
    /// 捕获一个 actor 既满足 Swift 6 严格并发，也不需要 `@unchecked Sendable`。
    private actor EndpointStub {
        private let byIdOutcome: StubOutcome
        private let currentUserOutcome: StubOutcome
        private var byIdArguments: [String] = []
        private var currentUserCallCount = 0

        init(byId: StubOutcome, currentUser: StubOutcome) {
            self.byIdOutcome = byId
            self.currentUserOutcome = currentUser
        }

        /// `GET /Users/{Id}`。
        func user(id: String) async throws -> EmbyUser {
            byIdArguments.append(id)
            switch byIdOutcome {
            case let .success(user):
                return user
            case let .failure(error):
                throw error
            }
        }

        /// `GET /Users/Me`。
        func currentUser() async throws -> EmbyUser {
            currentUserCallCount += 1
            switch currentUserOutcome {
            case let .success(user):
                return user
            case let .failure(error):
                throw error
            }
        }

        /// `fetchUserById` 收到的参数，按调用顺序。
        var recordedByIdArguments: [String] {
            byIdArguments
        }

        /// `fetchCurrentUser` 被调用的次数。
        var recordedCurrentUserCount: Int {
            currentUserCallCount
        }
    }

    /// 一次性环境：内存 Keychain + 独立 UserDefaults suite + 已组装好的恢复器。
    ///
    /// `UserDefaults` 不是 `Sendable`，所以这里只把**新创建的实例**交给 `ServerRegistry`，
    /// 自己不留引用；清理时再新建一个同 suite 的实例（同一 suite 的不同实例共享底层域）。
    private struct Fixture {
        let suiteName: String
        let secure: InMemorySecureStore
        let store: SessionStore
        let registry: ServerRegistry
        let restoration: SessionRestoration

        init() throws {
            let name = "test.prism.validator.\(UUID().uuidString)"
            suiteName = name
            secure = InMemorySecureStore()
            store = SessionStore(secureStore: secure)
            registry = ServerRegistry(defaults: try #require(UserDefaults(suiteName: name)))
            restoration = SessionRestoration(store: store, registry: registry)
        }

        func cleanUp() {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }

        /// 用伪造端点组装一个校验器。
        func validator(stub: EndpointStub) -> SessionValidator {
            SessionValidator(
                fetchUserById: { id in try await stub.user(id: id) },
                fetchCurrentUser: { try await stub.currentUser() },
                restoration: restoration
            )
        }

        /// 造一个「已登录」的现场：写入会话、登记服务器并标记为上次激活。
        ///
        /// 走 ``SessionRestoration/signIn(_:server:)`` 而不是直接写存储，是为了让
        /// 「401 之后服务器记录是否保留」这条断言面对真实的写入路径。
        func signIn(_ session: AuthSession, serverName: String = "客厅 Emby") async throws {
            let url = try #require(URL(string: "http://192.168.1.10:8096"))
            try await restoration.signIn(
                session,
                server: ServerConnection(id: session.serverId, name: serverName, baseURL: url)
            )
        }
    }

    /// 造一个会话。
    private func makeSession(
        serverId: String = "srv-a",
        userId: String = "alice",
        token: String = "token-abc",
        userName: String = "Alice"
    ) -> AuthSession {
        AuthSession(
            serverId: serverId,
            userId: userId,
            accessToken: token,
            user: EmbyUser(id: userId, name: userName, serverId: serverId),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    /// 造一个「服务器返回的用户」——故意与本地缓存的用户名不同，用来验证返回的是最新数据。
    private func makeServerUser(
        id: String = "alice",
        serverId: String = "srv-a",
        name: String = "Alice（服务器最新）"
    ) -> EmbyUser {
        EmbyUser(id: id, name: name, serverId: serverId)
    }

    // MARK: - 主路径

    @Test("主路径：/Users/{Id} 成功即返回该用户，且从不请求 /Users/Me")
    func primaryPathSucceedsWithoutFallback() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = makeSession()
        try await fixture.signIn(session)

        let fresh = makeServerUser()
        let stub = EndpointStub(byId: .success(fresh), currentUser: .success(makeServerUser(name: "不该被用到")))
        let validator = fixture.validator(stub: stub)

        let user = try await validator.validate(session)

        // 返回的是服务器上的最新对象，不是本地缓存的那份
        #expect(user == fresh)
        #expect(user?.name == "Alice（服务器最新）")
        // 只打了一个端点，而且用的是会话里的 userId
        #expect(await stub.recordedByIdArguments == [session.userId])
        // 关键断言：成功路径绝不能顺手再打 /Users/Me（那会让 Emby 每次都多一次 404）
        #expect(await stub.recordedCurrentUserCount == 0)
        // token 当然不该被动
        #expect(try await fixture.store.session(serverId: "srv-a", userId: "alice")?.accessToken == "token-abc")
    }

    @Test("Emby 场景：服务器没有 /Users/Me，仅靠 /Users/{Id} 也能校验通过")
    func embyWorksWithoutCurrentUserEndpoint() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = makeSession()
        try await fixture.signIn(session)

        let fresh = makeServerUser(name: "Emby 用户")
        // Emby 4.8 上 /Users/Me 就是 404：把它设成 notFound，结果也必须不受影响
        let stub = EndpointStub(byId: .success(fresh), currentUser: .failure(.notFound))
        let validator = fixture.validator(stub: stub)

        let user = try await validator.validate(session)

        #expect(user == fresh)
        #expect(await stub.recordedCurrentUserCount == 0)
        // 会话完好：Emby 用户不该因为「Jellyfin 专属端点不存在」而被登出
        #expect(try await fixture.store.session(serverId: "srv-a", userId: "alice") != nil)
        #expect(await fixture.restoration.knownServers().count == 1)
    }

    // MARK: - 404 回退

    @Test("/Users/{Id} 返回 404 时回退 /Users/Me，且只回退一次")
    func fallsBackToCurrentUserOnNotFound() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = makeSession()
        try await fixture.signIn(session)

        let fresh = makeServerUser(name: "Jellyfin 用户")
        let stub = EndpointStub(byId: .failure(.notFound), currentUser: .success(fresh))
        let validator = fixture.validator(stub: stub)

        let user = try await validator.validate(session)

        #expect(user == fresh)
        // 先按 userId 查（Emby 支持），失败后才用 /Users/Me 兜底（Jellyfin 兼容）
        #expect(await stub.recordedByIdArguments == [session.userId])
        #expect(await stub.recordedCurrentUserCount == 1)
        // 回退成功说明 token 有效，不能清
        #expect(try await fixture.store.session(serverId: "srv-a", userId: "alice") != nil)
    }

    // MARK: - 401

    @Test("401：返回 nil，并清掉该服务器在 SessionStore 里的 token")
    func unauthorizedClearsToken() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = makeSession()
        try await fixture.signIn(session)

        let stub = EndpointStub(byId: .failure(.unauthorized), currentUser: .success(makeServerUser()))
        let validator = fixture.validator(stub: stub)

        let user = try await validator.validate(session)

        #expect(user == nil)
        // markLoggedOut 生效：这台服务器上没有会话了
        #expect(try await fixture.store.session(serverId: "srv-a", userId: "alice") == nil)
        #expect(try await fixture.store.loadAll().isEmpty)
        #expect(try await fixture.store.active() == nil)
        // 401 已经是结论，不需要再试第二个端点
        #expect(await stub.recordedCurrentUserCount == 0)
    }

    @Test("401 只清 token：服务器记录（地址、名称）与上次激活提示都保留")
    func unauthorizedKeepsServerRecord() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = makeSession()
        try await fixture.signIn(session, serverName: "客厅 Emby")

        let stub = EndpointStub(byId: .failure(.unauthorized), currentUser: .failure(.unauthorized))
        let validator = fixture.validator(stub: stub)

        let user = try await validator.validate(session)

        #expect(user == nil)
        #expect(try await fixture.store.session(serverId: "srv-a", userId: "alice") == nil)

        // 服务器记录必须还在：用户重新登录时只需输密码，不用重填地址
        let kept = await fixture.registry.server(id: "srv-a")
        #expect(kept?.name == "客厅 Emby")
        #expect(kept?.baseURL == URL(string: "http://192.168.1.10:8096"))
        #expect(await fixture.registry.lastActiveServerId == "srv-a")

        // 启动恢复会回到登录页，但登录页能直接列出这台服务器
        #expect(try await fixture.restoration.restore() == .signedOut)
        #expect(await fixture.restoration.knownServers().count == 1)
    }

    @Test("401 只影响当前服务器，其他服务器的会话不受牵连")
    func unauthorizedOnlyClearsTargetServer() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let target = makeSession(serverId: "srv-a", userId: "alice")
        let other = makeSession(serverId: "srv-b", userId: "bob", token: "token-b")
        try await fixture.signIn(target)
        try await fixture.signIn(other, serverName: "书房 Emby")

        let stub = EndpointStub(byId: .failure(.unauthorized), currentUser: .failure(.unauthorized))
        let validator = fixture.validator(stub: stub)

        #expect(try await validator.validate(target) == nil)

        #expect(try await fixture.store.session(serverId: "srv-a", userId: "alice") == nil)
        #expect(try await fixture.store.session(serverId: "srv-b", userId: "bob")?.accessToken == "token-b")
        #expect(await fixture.registry.server(id: "srv-b") != nil)
    }

    // MARK: - 两个端点都不可用

    @Test("两个端点都 404：视为会话失效，返回 nil 并清 token")
    func bothEndpointsNotFoundClearsToken() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = makeSession()
        try await fixture.signIn(session)

        let stub = EndpointStub(byId: .failure(.notFound), currentUser: .failure(.notFound))
        let validator = fixture.validator(stub: stub)

        let user = try await validator.validate(session)

        #expect(user == nil)
        #expect(await stub.recordedByIdArguments == [session.userId])
        #expect(await stub.recordedCurrentUserCount == 1)
        #expect(try await fixture.store.session(serverId: "srv-a", userId: "alice") == nil)
        // 服务器记录仍然保留，理由同 401
        #expect(await fixture.registry.server(id: "srv-a") != nil)
    }

    @Test("回退路径上的 401：返回 nil 并清 token")
    func fallbackUnauthorizedClearsToken() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = makeSession()
        try await fixture.signIn(session)

        let stub = EndpointStub(byId: .failure(.notFound), currentUser: .failure(.unauthorized))
        let validator = fixture.validator(stub: stub)

        let user = try await validator.validate(session)

        #expect(user == nil)
        #expect(await stub.recordedCurrentUserCount == 1)
        #expect(try await fixture.store.session(serverId: "srv-a", userId: "alice") == nil)
    }

    // MARK: - 网络错误必须向上抛（离线不登出）

    @Test("超时向上抛而不是返回 nil——离线时不该把用户登出")
    func timeoutPropagatesAndKeepsToken() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = makeSession()
        try await fixture.signIn(session)

        let stub = EndpointStub(byId: .failure(.timeout), currentUser: .success(makeServerUser()))
        let validator = fixture.validator(stub: stub)

        await #expect(throws: EmbyError.timeout) {
            _ = try await validator.validate(session)
        }

        // 抛错 ≠ 登出：token 必须原样保留
        #expect(try await fixture.store.session(serverId: "srv-a", userId: "alice")?.accessToken == "token-abc")
        // 也不该继续去打 /Users/Me 把网络错误掩盖掉
        #expect(await stub.recordedCurrentUserCount == 0)
        // 下次启动仍然能恢复成已登录（离线可用）
        #expect(try await fixture.restoration.restore() == .signedIn(session))
    }

    @Test("服务器不可达同样向上抛，且 token 没有被清除")
    func serverUnreachablePropagatesAndKeepsToken() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = makeSession()
        try await fixture.signIn(session)

        let unreachable = EmbyError.serverUnreachable("无法连接到主机")
        let stub = EndpointStub(byId: .failure(unreachable), currentUser: .success(makeServerUser()))
        let validator = fixture.validator(stub: stub)

        await #expect(throws: unreachable) {
            _ = try await validator.validate(session)
        }

        #expect(try await fixture.store.session(serverId: "srv-a", userId: "alice") != nil)
        #expect(try await fixture.store.loadAll().count == 1)
        #expect(await stub.recordedCurrentUserCount == 0)
    }

    @Test("回退路径上的超时：抛错且 token 保留")
    func fallbackTimeoutPropagatesAndKeepsToken() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = makeSession()
        try await fixture.signIn(session)

        // 第一跳 404 是「userId 不存在」，第二跳超时是「网络没了」——后者不能升级成登出
        let stub = EndpointStub(byId: .failure(.notFound), currentUser: .failure(.timeout))
        let validator = fixture.validator(stub: stub)

        await #expect(throws: EmbyError.timeout) {
            _ = try await validator.validate(session)
        }

        #expect(await stub.recordedCurrentUserCount == 1)
        #expect(try await fixture.store.session(serverId: "srv-a", userId: "alice")?.accessToken == "token-abc")
    }
}
