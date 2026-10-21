import Foundation
import Testing
import PrismCore
@testable import PrismData

/// ``SessionRestoration``：启动恢复与 401 处理。
///
/// 语义已随「存密码而不是 token」调整：
/// - 本机存的是凭据，启动恢复只能给出「需要重新登录」的意图，真正的
///   `AuthSession` 要联网换取（由 `SessionBootstrapper` 完成）。
/// - 因此这里断言的是「凭据 + 服务器能否拼出可登录的组合」，
///   而不是「能否直接恢复出一个有效 token」。
@Suite("SessionRestoration", .serialized)
struct SessionRestorationTests {
    // MARK: 夹具

    /// 一次性环境：内存存储 + 独立 UserDefaults suite。
    ///
    /// `UserDefaults` 不是 `Sendable`，所以这里只把**新创建的实例**交给 `ServerRegistry`，
    /// 自己不留引用；清理时再新建一个同 suite 的实例（同一 suite 的不同实例共享底层域）。
    private struct Fixture {
        let suiteName: String
        let secure: InMemorySecureStore
        let store: CredentialStore
        let registry: ServerRegistry
        let restoration: SessionRestoration

        init() throws {
            let name = "test.prism.\(UUID().uuidString)"
            suiteName = name
            secure = InMemorySecureStore()
            store = CredentialStore(secureStore: secure)
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

    private func makeCredential(
        serverId: String = "srv-a",
        userId: String = "alice",
        username: String = "alice",
        password: String = "secret"
    ) -> StoredCredential {
        StoredCredential(
            serverId: serverId,
            userId: userId,
            username: username,
            password: password,
            lastSignedInAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeServer(id: String = "srv-a", name: String = "客厅") throws -> ServerConnection {
        let url = try #require(URL(string: "http://192.168.1.10:8096"))
        return ServerConnection(id: id, name: name, baseURL: url)
    }

    // MARK: 启动恢复

    @Test("全新安装：恢复结果是未登录")
    func restoreWithoutCredential() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let state = try await fixture.restoration.restore()

        #expect(state == .signedOut)
        #expect(await fixture.restoration.knownServers().isEmpty)
    }

    @Test("登录后重启：恢复出「需要重新登录」以及凭据与服务器")
    func restoreYieldsReloginIntent() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let server = try makeServer()

        try await fixture.restoration.signIn(
            makeSession(),
            username: "alice",
            password: "secret",
            server: server
        )
        let state = try await fixture.restoration.restore()

        guard case let .needsRelogin(credential, restoredServer) = state else {
            Issue.record("应当返回 needsRelogin，实际 \(state)")
            return
        }
        #expect(credential.username == "alice")
        #expect(credential.password == "secret")
        #expect(credential.serverId == "srv-a")
        #expect(restoredServer.id == "srv-a")
        #expect(restoredServer.baseURL == server.baseURL)
    }

    @Test("signIn 会把服务器登记进 registry 并标记为上次激活")
    func signInRegistersServer() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let server = try makeServer()

        try await fixture.restoration.signIn(
            makeSession(),
            username: "alice",
            password: "secret",
            server: server
        )

        #expect(await fixture.registry.server(id: "srv-a") != nil)
        #expect(await fixture.registry.lastActiveServerId == "srv-a")
        #expect(await fixture.registry.servers().count == 1)
    }

    @Test("多服务器时恢复出 active 标记的那一条")
    func restoreActiveAmongMany() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.registry.upsert(try makeServer(id: "srv-a"))
        await fixture.registry.upsert(try makeServer(id: "srv-b"))

        try await fixture.store.save(makeCredential(serverId: "srv-a", userId: "alice"))
        try await fixture.store.save(makeCredential(serverId: "srv-b", userId: "alice"))
        try await fixture.store.setActive(serverId: "srv-b", userId: "alice")

        let state = try await fixture.restoration.restore()

        guard case let .needsRelogin(credential, _) = state else {
            Issue.record("应当返回 needsRelogin，实际 \(state)")
            return
        }
        #expect(credential.serverId == "srv-b")
    }

    @Test("密码为空的凭据不算可用，恢复结果为未登录")
    func restoreTreatsEmptyPasswordAsSignedOut() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.registry.upsert(try makeServer())
        try await fixture.store.save(makeCredential(password: ""))

        let state = try await fixture.restoration.restore()

        #expect(state == .signedOut)
    }

    @Test("服务器记录缺失时无法登录：返回未登录而不是崩溃")
    func restoreWithoutServerRecordIsSignedOut() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        // 只有凭据，registry 里没有这台服务器。
        try await fixture.store.save(makeCredential(serverId: "srv-unknown"))

        let state = try await fixture.restoration.restore()

        // 地址是发请求的前提，缺了只能让用户重选服务器。
        #expect(state == .signedOut)
    }

    @Test("恢复时把 registry 的「上次激活」校正成实际凭据所在的服务器")
    func restoreReconcilesLastActiveHint() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.registry.upsert(try makeServer(id: "srv-a", name: "客厅"))
        await fixture.registry.upsert(try makeServer(id: "srv-b", name: "书房"))
        await fixture.registry.setLastActiveServerId("srv-b")
        // 实际凭据在 srv-a。
        try await fixture.store.save(makeCredential(serverId: "srv-a"))

        _ = try await fixture.restoration.restore()

        #expect(await fixture.registry.lastActiveServerId == "srv-a")
    }

    // MARK: 登出 / 失效

    @Test("invalidate 后凭据没了，但服务器记录仍在")
    func invalidateKeepsServerRecord() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let server = try makeServer()
        try await fixture.restoration.signIn(
            makeSession(),
            username: "alice",
            password: "secret",
            server: server
        )

        try await fixture.restoration.invalidate(serverId: "srv-a")

        // 凭据已清。
        #expect(try await fixture.store.loadAll().isEmpty)
        // 服务器记录与提示都保留：用户只需重输密码，不用重填地址。
        let kept = await fixture.registry.server(id: "srv-a")
        #expect(kept?.id == server.id)
        #expect(kept?.name == server.name)
        #expect(kept?.baseURL == server.baseURL)
        #expect(await fixture.registry.lastActiveServerId == "srv-a")
        // 恢复流程回到未登录。
        #expect(try await fixture.restoration.restore() == .signedOut)
    }

    @Test("invalidate 只清目标服务器，其他服务器的凭据不受影响")
    func invalidateOnlyAffectsTargetServer() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try await fixture.restoration.signIn(
            makeSession(serverId: "srv-a"),
            username: "alice",
            password: "secret",
            server: try makeServer(id: "srv-a")
        )
        try await fixture.restoration.signIn(
            makeSession(serverId: "srv-b"),
            username: "alice",
            password: "secret",
            server: try makeServer(id: "srv-b")
        )

        try await fixture.restoration.invalidate(serverId: "srv-a")

        #expect(try await fixture.store.credential(serverId: "srv-a", userId: "alice") == nil)
        #expect(try await fixture.store.credential(serverId: "srv-b", userId: "alice") != nil)
        #expect(await fixture.registry.servers().count == 2)
    }

    @Test("invalidate 之后再登录一次即可恢复")
    func reSignInAfterInvalidate() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let server = try makeServer()
        try await fixture.restoration.signIn(
            makeSession(),
            username: "alice",
            password: "old",
            server: server
        )
        try await fixture.restoration.invalidate(serverId: "srv-a")

        try await fixture.restoration.signIn(
            makeSession(),
            username: "alice",
            password: "new",
            server: server
        )

        let state = try await fixture.restoration.restore()
        guard case let .needsRelogin(credential, _) = state else {
            Issue.record("应当返回 needsRelogin，实际 \(state)")
            return
        }
        #expect(credential.password == "new")
    }
}