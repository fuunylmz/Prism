import Foundation
import Testing
import PrismCore
@testable import PrismData

/// ``CredentialStore`` 的行为契约。
///
/// 全部用例注入 ``InMemorySecureStore``，**不触碰真实磁盘**。
///
/// 这个类型存的是「服务器 + 用户名 + 密码」，而不是 token。
/// 改动语义时要同步想清楚一件事：密码失效后必须重新登录，
/// 而 token 失效是可以自动续的——两者不可混为一谈。
@Suite("CredentialStore")
struct CredentialStoreTests {
    // MARK: 夹具

    /// 造一条凭据。
    private func makeCredential(
        serverId: String = "srv-1",
        userId: String = "user-1",
        username: String = "alice",
        password: String = "secret-123",
        lastSignedInAt: Date? = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> StoredCredential {
        StoredCredential(
            serverId: serverId,
            userId: userId,
            username: username,
            password: password,
            lastSignedInAt: lastSignedInAt
        )
    }

    /// 造一个「空存储 + CredentialStore」组合。
    private func makeStore(
        service: String = CredentialStore.defaultService
    ) -> (CredentialStore, InMemorySecureStore) {
        let secure = InMemorySecureStore()
        return (CredentialStore(secureStore: secure, service: service), secure)
    }

    // MARK: 基本往返

    @Test("保存后读回，字段完全一致（含密码）")
    func saveAndLoadRoundTrip() async throws {
        let (store, _) = makeStore()
        let credential = makeCredential()

        try await store.save(credential)
        let all = try await store.loadAll()

        #expect(all.count == 1)
        #expect(all.first == credential)
        #expect(all.first?.username == "alice")
        #expect(all.first?.password == "secret-123")
        #expect(all.first?.serverId == "srv-1")
        #expect(all.first?.userId == "user-1")
    }

    @Test("模拟进程重启：换一个实例仍能读回")
    func survivesInstanceRecreation() async throws {
        let secure = InMemorySecureStore()
        let credential = makeCredential()

        try await CredentialStore(secureStore: secure).save(credential)
        let reloaded = try await CredentialStore(secureStore: secure).loadAll()

        #expect(reloaded == [credential])
    }

    @Test("重复保存同一凭据是覆盖，不是追加")
    func saveOverwritesSameCredential() async throws {
        let (store, _) = makeStore()

        try await store.save(makeCredential(password: "old"))
        try await store.save(makeCredential(password: "new"))

        let all = try await store.loadAll()
        #expect(all.count == 1)
        #expect(all.first?.password == "new")
    }

    @Test("同一服务器不同用户是两条独立凭据")
    func differentUsersCoexist() async throws {
        let (store, _) = makeStore()

        try await store.save(makeCredential(userId: "alice"))
        try await store.save(makeCredential(userId: "bob"))

        #expect(try await store.loadAll().count == 2)
    }

    // MARK: active 语义

    @Test("第一条保存的凭据自动成为 active")
    func firstCredentialBecomesActive() async throws {
        let (store, _) = makeStore()
        let credential = makeCredential()

        try await store.save(credential)

        #expect(try await store.active() == credential)
    }

    @Test("setActive 切换生效")
    func setActiveSwitches() async throws {
        let (store, _) = makeStore()
        try await store.save(makeCredential(serverId: "srv-a", userId: "a"))
        try await store.save(makeCredential(serverId: "srv-b", userId: "b"))

        try await store.setActive(serverId: "srv-b", userId: "b")

        #expect(try await store.active()?.serverId == "srv-b")
    }

    @Test("setActive 指向不存在的凭据会抛错")
    func setActiveRequiresExisting() async throws {
        let (store, _) = makeStore()

        await #expect(throws: SessionStoreError.sessionNotFound(serverId: "ghost", userId: "nobody")) {
            try await store.setActive(serverId: "ghost", userId: "nobody")
        }
    }

    @Test("active 指向的凭据被删后，回退到最新的一条")
    func activeFallsBackToMostRecent() async throws {
        let (store, _) = makeStore()
        let older = makeCredential(
            serverId: "srv-old",
            userId: "u1",
            lastSignedInAt: Date(timeIntervalSince1970: 1_600_000_000)
        )
        let newer = makeCredential(
            serverId: "srv-new",
            userId: "u2",
            lastSignedInAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try await store.save(older)
        try await store.save(newer)
        try await store.setActive(serverId: "srv-old", userId: "u1")

        try await store.remove(serverId: "srv-old")

        // 剩下的唯一一条就是最新的那条。
        #expect(try await store.active()?.serverId == "srv-new")
    }

    @Test("空存储时 active 返回 nil")
    func activeOnEmptyStore() async throws {
        let (store, _) = makeStore()

        #expect(try await store.active() == nil)
    }

    // MARK: 删除

    @Test("登出只删该服务器的凭据，其它服务器不受影响")
    func markLoggedOutIsScoped() async throws {
        let (store, _) = makeStore()
        try await store.save(makeCredential(serverId: "srv-a", userId: "a"))
        try await store.save(makeCredential(serverId: "srv-b", userId: "b"))

        try await store.markLoggedOut(serverId: "srv-a")

        let remaining = try await store.loadAll()
        #expect(remaining.count == 1)
        #expect(remaining.first?.serverId == "srv-b")
    }

    @Test("删除不存在的服务器不抛错")
    func removeIsIdempotent() async throws {
        let (store, _) = makeStore()

        try await store.remove(serverId: "never-existed")
    }

    @Test("removeAll 清空全部凭据")
    func removeAllClears() async throws {
        let (store, _) = makeStore()
        try await store.save(makeCredential(serverId: "srv-a", userId: "a"))
        try await store.save(makeCredential(serverId: "srv-b", userId: "b"))

        try await store.removeAll()

        #expect(try await store.loadAll().isEmpty)
        #expect(try await store.active() == nil)
    }

    // MARK: 旧数据迁移

    @Test("清理旧版 token 文件，不误删新凭据")
    func legacyTokenFileIsRemoved() async throws {
        let (store, secure) = makeStore()
        // 模拟升级前留下的 token 文件。
        try secure.save(
            Data("old-token".utf8),
            account: "sessions.v1",
            service: CredentialStore.defaultService
        )
        try await store.save(makeCredential())

        await store.removeLegacyTokenFile()

        #expect(
            try secure.load(account: "sessions.v1", service: CredentialStore.defaultService) == nil
        )
        // 新凭据必须还在。
        #expect(try await store.loadAll().count == 1)
    }

    // MARK: 损坏与版本

    @Test("读到损坏数据时抛 decoding，而不是静默当成空")
    func corruptedPayloadThrows() async throws {
        let (store, secure) = makeStore()
        try secure.save(
            Data("not json".utf8),
            account: "credentials.v1",
            service: CredentialStore.defaultService
        )

        await #expect(throws: SessionStoreError.self) {
            try await store.loadAll()
        }
    }

    @Test("读到更高版本时明确报错")
    func futureSchemaVersionThrows() async throws {
        let (store, secure) = makeStore()
        let future = """
        {"schemaVersion": 99, "credentials": [], "active": null}
        """
        try secure.save(
            Data(future.utf8),
            account: "credentials.v1",
            service: CredentialStore.defaultService
        )

        await #expect(throws: SessionStoreError.self) {
            try await store.loadAll()
        }
    }

    // MARK: 凭据可用性

    @Test("缺用户名或密码的凭据标记为不可用")
    func unusableCredential() {
        #expect(makeCredential().isUsable)
        #expect(!makeCredential(username: "").isUsable)
        #expect(!makeCredential(password: "").isUsable)
        #expect(!makeCredential(serverId: "").isUsable)
    }

    @Test("脱敏描述绝不包含密码原文")
    func redactedDescriptionHidesPassword() {
        let credential = makeCredential(password: "super-secret")

        #expect(!credential.redactedDescription.contains("super-secret"))
        #expect(credential.redactedDescription.contains("***"))
    }
}