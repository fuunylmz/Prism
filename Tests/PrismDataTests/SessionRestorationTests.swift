import Foundation
import Testing
import PrismCore
@testable import PrismData

/// ``SessionRestoration``：启动恢复与 401 处理。
@Suite("SessionRestoration", .serialized)
struct SessionRestorationTests {
    // MARK: 夹具

    /// 一次性环境：内存 Keychain + 独立 UserDefaults suite。
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
            let name = "test.prism.\(UUID().uuidString)"
            suiteName = name
            secure = InMemorySecureStore()
            store = SessionStore(secureStore: secure)
            registry = ServerRegistry(defaults: try #require(UserDefaults(suiteName: name)))
            restoration = SessionRestoration(store: store, registry: registry)
        }

        func cleanUp() {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
    }

    private func makeSession(
        serverId: String = "srv-a",
        userId: String = "alice",
        token: String = "token-abc"
    ) -> AuthSession {
        AuthSession(
            serverId: serverId,
            userId: userId,
            accessToken: token,
            user: EmbyUser(id: userId, name: "Alice", serverId: serverId),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeServer(id: String = "srv-a", name: String = "客厅") throws -> ServerConnection {
        let url = try #require(URL(string: "http://192.168.1.10:8096"))
        return ServerConnection(id: id, name: name, baseURL: url)
    }

    // MARK: 启动恢复

    @Test("全新安装：恢复结果是未登录")
    func restoreWithoutSession() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let state = try await fixture.restoration.restore()

        #expect(state == .signedOut)
        #expect(await fixture.restoration.knownServers().isEmpty)
    }

    @Test("登录后重启：恢复出同一个会话")
    func restoreSignedIn() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let session = makeSession()
        let server = try makeServer()

        try await fixture.restoration.signIn(session, server: server)
        let state = try await fixture.restoration.restore()

        #expect(state == .signedIn(session))
    }

    @Test("signIn 会把服务器登记进 registry 并标记为上次激活")
    func signInRegistersServer() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let server = try makeServer()

        try await fixture.restoration.signIn(makeSession(), server: server)

        #expect(await fixture.registry.server(id: "srv-a") != nil)
        #expect(await fixture.registry.lastActiveServerId == "srv-a")
        #expect(await fixture.registry.servers().count == 1)
    }

    @Test("多服务器时恢复出 active 标记的那一个")
    func restoreActiveAmongMany() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        try await fixture.store.save(makeSession(serverId: "srv-a", userId: "alice"))
        try await fixture.store.save(makeSession(serverId: "srv-b", userId: "alice"))
        try await fixture.store.setActive(serverId: "srv-b", userId: "alice")

        let state = try await fixture.restoration.restore()

        #expect(state == .signedIn(makeSession(serverId: "srv-b", userId: "alice")))
    }

    @Test("令牌为空的会话不算已登录")
    func restoreTreatsEmptyTokenAsSignedOut() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try await fixture.store.save(makeSession(token: ""))

        let state = try await fixture.restoration.restore()

        #expect(state == .signedOut)
    }

    @Test("恢复时把 registry 的「上次激活」校正成实际会话所在的服务器")
    func restoreReconcilesLastActiveHint() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        // 两台服务器都登记过，但提示指向 srv-b
        await fixture.registry.upsert(try makeServer(id: "srv-a", name: "客厅"))
        await fixture.registry.upsert(try makeServer(id: "srv-b", name: "书房"))
        await fixture.registry.setLastActiveServerId("srv-b")
        // 实际会话在 srv-a
        try await fixture.store.save(makeSession(serverId: "srv-a"))

        _ = try await fixture.restoration.restore()

        #expect(await fixture.registry.lastActiveServerId == "srv-a")
    }

    @Test("服务器记录缺失不影响「已登录」判定")
    func restoreIgnoresMissingServerRecord() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        // 只存会话，registry 里没有这台服务器
        try await fixture.store.save(makeSession(serverId: "srv-unknown"))

        let state = try await fixture.restoration.restore()

        #expect(state == .signedIn(makeSession(serverId: "srv-unknown")))
        // 不写入悬空提示
        #expect(await fixture.registry.lastActiveServerId == nil)
    }

    // MARK: 401 / invalidate

    @Test("invalidate 后 token 没了，但服务器记录仍在")
    func invalidateKeepsServerRecord() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let server = try makeServer()
        try await fixture.restoration.signIn(makeSession(), server: server)

        try await fixture.restoration.invalidate(serverId: "srv-a")

        // token 已清
        #expect(try await fixture.store.loadAll().isEmpty)
        #expect(try await fixture.store.session(serverId: "srv-a", userId: "alice") == nil)
        // 服务器记录与提示都保留：用户只需重输密码，不用重填地址
        let kept = await fixture.registry.server(id: "srv-a")
        #expect(kept?.id == server.id)
        #expect(kept?.name == server.name)
        #expect(kept?.baseURL == server.baseURL)
        #expect(await fixture.registry.lastActiveServerId == "srv-a")
        // 恢复流程回到未登录
        #expect(try await fixture.restoration.restore() == .signedOut)
    }

    @Test("invalidate 只清目标服务器，其他服务器的会话不受影响")
    func invalidateOnlyAffectsTargetServer() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try await fixture.restoration.signIn(makeSession(serverId: "srv-a"), server: try makeServer(id: "srv-a"))
        try await fixture.restoration.signIn(makeSession(serverId: "srv-b"), server: try makeServer(id: "srv-b"))

        try await fixture.restoration.invalidate(serverId: "srv-a")

        #expect(try await fixture.store.session(serverId: "srv-a", userId: "alice") == nil)
        #expect(try await fixture.store.session(serverId: "srv-b", userId: "alice") != nil)
        #expect(await fixture.registry.servers().count == 2)
    }

    @Test("invalidate 之后再登录一次即可恢复")
    func reSignInAfterInvalidate() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let server = try makeServer()
        try await fixture.restoration.signIn(makeSession(token: "old"), server: server)
        try await fixture.restoration.invalidate(serverId: "srv-a")

        try await fixture.restoration.signIn(makeSession(token: "new"), server: server)

        let state = try await fixture.restoration.restore()
        #expect(state == .signedIn(makeSession(token: "new")))
    }
}
