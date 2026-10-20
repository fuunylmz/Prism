import Foundation
import Testing
import PrismCore
@testable import PrismData

/// ``SessionStore`` 的行为契约。
///
/// 全部用例注入 ``InMemorySecureStore``，**不触碰真实 Keychain**。
@Suite("SessionStore")
struct SessionStoreTests {
    // MARK: 夹具

    /// 造一个会话。
    private func makeSession(
        serverId: String = "srv-1",
        userId: String = "user-1",
        token: String = "token-abc",
        userName: String = "Alice",
        createdAt: Date? = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> AuthSession {
        let user = EmbyUser(
            id: userId,
            name: userName,
            serverId: serverId,
            isAdministrator: true,
            primaryImageTag: "img-tag",
            serverName: "客厅 Emby",
            hasPassword: true,
            lastLoginDate: Date(timeIntervalSince1970: 1_699_000_000)
        )
        return AuthSession(
            serverId: serverId,
            userId: userId,
            accessToken: token,
            user: user,
            createdAt: createdAt
        )
    }

    /// 造一个「空存储 + SessionStore」组合。
    private func makeStore(
        service: String = SessionStore.defaultService
    ) -> (SessionStore, InMemorySecureStore) {
        let secure = InMemorySecureStore()
        return (SessionStore(secureStore: secure, service: service), secure)
    }

    // MARK: 基本往返

    @Test("保存后读回，字段完全一致")
    func saveAndLoadRoundTrip() async throws {
        let (store, _) = makeStore()
        let session = makeSession()

        try await store.save(session)
        let all = try await store.loadAll()

        #expect(all.count == 1)
        #expect(all.first == session)
        // 逐字段再断言一遍，避免「整体相等」掩盖了某个字段被改写的可能
        #expect(all.first?.accessToken == "token-abc")
        #expect(all.first?.serverId == "srv-1")
        #expect(all.first?.userId == "user-1")
        #expect(all.first?.user.name == "Alice")
        #expect(all.first?.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("模拟进程重启：换一个 SessionStore 实例仍能读回")
    func survivesInstanceRecreation() async throws {
        let secure = InMemorySecureStore()
        let session = makeSession()

        try await SessionStore(secureStore: secure).save(session)
        let reloaded = try await SessionStore(secureStore: secure).loadAll()

        #expect(reloaded == [session])
    }

    @Test("重复保存同一会话是覆盖，不是追加")
    func saveOverwritesSameSession() async throws {
        let (store, _) = makeStore()
        let first = makeSession(token: "old")
        let second = makeSession(token: "new")

        try await store.save(first)
        try await store.save(second)

        let all = try await store.loadAll()
        #expect(all.count == 1)
        #expect(all.first?.accessToken == "new")
    }

    @Test("loadAll 保持写入顺序")
    func loadAllKeepsInsertionOrder() async throws {
        let (store, _) = makeStore()
        try await store.save(makeSession(serverId: "a", userId: "u", createdAt: Date(timeIntervalSince1970: 300)))
        try await store.save(makeSession(serverId: "b", userId: "u", createdAt: Date(timeIntervalSince1970: 100)))
        try await store.save(makeSession(serverId: "c", userId: "u", createdAt: Date(timeIntervalSince1970: 200)))

        let ids = try await store.loadAll().map(\.serverId)
        #expect(ids == ["a", "b", "c"])
    }

    // MARK: 多服务器 / 多用户

    @Test("多服务器多用户共存，互不干扰")
    func multipleServersAndUsers() async throws {
        let (store, _) = makeStore()
        let a = makeSession(serverId: "srv-a", userId: "alice", token: "token-a")
        let b = makeSession(serverId: "srv-a", userId: "bob", token: "token-b")
        let c = makeSession(serverId: "srv-b", userId: "alice", token: "token-c")

        try await store.save(a)
        try await store.save(b)
        try await store.save(c)

        #expect(try await store.loadAll().count == 3)
        #expect(try await store.session(serverId: "srv-a", userId: "alice")?.accessToken == "token-a")
        #expect(try await store.session(serverId: "srv-a", userId: "bob")?.accessToken == "token-b")
        #expect(try await store.session(serverId: "srv-b", userId: "alice")?.accessToken == "token-c")
        #expect(try await store.session(serverId: "srv-b", userId: "bob") == nil)
    }

    @Test("无论多少个会话，Keychain 里始终只有一条 item")
    func singleKeychainItemForAllSessions() async throws {
        let (store, secure) = makeStore()
        try await store.save(makeSession(serverId: "srv-a", userId: "alice"))
        try await store.save(makeSession(serverId: "srv-b", userId: "alice"))
        try await store.save(makeSession(serverId: "srv-b", userId: "bob"))
        try await store.setActive(serverId: "srv-b", userId: "bob")

        // 存储形态是「一个 JSON blob」，不是每字段/每服务器一条 item
        #expect(secure.count == 1)
        #expect(try await store.loadAll().count == 3)
    }

    @Test("删除单个会话不影响同服务器上的其他用户")
    func removeSingleUserKeepsOthers() async throws {
        let (store, _) = makeStore()
        try await store.save(makeSession(serverId: "srv-a", userId: "alice"))
        try await store.save(makeSession(serverId: "srv-a", userId: "bob"))

        try await store.remove(serverId: "srv-a", userId: "alice")

        #expect(try await store.session(serverId: "srv-a", userId: "alice") == nil)
        #expect(try await store.session(serverId: "srv-a", userId: "bob") != nil)
    }

    @Test("remove(serverId:) 清掉该服务器的所有用户，其他服务器保留")
    func removeServerRemovesAllItsUsers() async throws {
        let (store, _) = makeStore()
        try await store.save(makeSession(serverId: "srv-a", userId: "alice"))
        try await store.save(makeSession(serverId: "srv-a", userId: "bob"))
        try await store.save(makeSession(serverId: "srv-b", userId: "alice"))

        try await store.remove(serverId: "srv-a")

        let remaining = try await store.loadAll()
        #expect(remaining.count == 1)
        #expect(remaining.first?.serverId == "srv-b")
    }

    // MARK: active

    @Test("没有任何会话时 active() 为 nil")
    func activeIsNilWhenEmpty() async throws {
        let (store, _) = makeStore()

        #expect(try await store.active() == nil)
        #expect(try await store.loadAll().isEmpty)
    }

    @Test("首个保存的会话自动成为 active（登录后立刻重启也能免登录）")
    func firstSaveBecomesActive() async throws {
        let (store, _) = makeStore()
        let first = makeSession(serverId: "srv-a", userId: "alice")
        let second = makeSession(serverId: "srv-b", userId: "alice")

        try await store.save(first)
        #expect(try await store.active() == first)

        // 后续保存不抢 active
        try await store.save(second)
        #expect(try await store.active() == first)
    }

    @Test("setActive 切换后 active() 返回标记的那一个")
    func setActiveSwitches() async throws {
        let (store, _) = makeStore()
        let a = makeSession(serverId: "srv-a", userId: "alice")
        let b = makeSession(serverId: "srv-b", userId: "alice")
        try await store.save(a)
        try await store.save(b)

        try await store.setActive(serverId: "srv-b", userId: "alice")

        #expect(try await store.active() == b)
    }

    @Test("setActive 指向不存在的会话时抛 sessionNotFound")
    func setActiveUnknownThrows() async throws {
        let (store, _) = makeStore()

        await #expect(throws: SessionStoreError.sessionNotFound(serverId: "ghost", userId: "nobody")) {
            try await store.setActive(serverId: "ghost", userId: "nobody")
        }
    }

    @Test("删除 active 后回退到剩余的「最新」会话")
    func removeActiveFallsBackToMostRecent() async throws {
        let (store, _) = makeStore()
        let older = makeSession(
            serverId: "srv-old", userId: "alice",
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let newer = makeSession(
            serverId: "srv-new", userId: "alice",
            createdAt: Date(timeIntervalSince1970: 2_000)
        )
        try await store.save(older)
        try await store.save(newer)
        try await store.setActive(serverId: "srv-new", userId: "alice")

        try await store.remove(serverId: "srv-new", userId: "alice")

        // 回退规则：createdAt 更晚者优先 → older（此时只剩它）
        #expect(try await store.active() == older)
    }

    @Test("active 标记丢失（历史数据）时，active() 回退到 createdAt 最新的会话")
    func activeFallsBackToNewestWhenMarkerMissing() async throws {
        let (store, secure) = makeStore()
        let old = makeSession(serverId: "srv-old", userId: "alice", createdAt: Date(timeIntervalSince1970: 1_000))
        let new = makeSession(serverId: "srv-new", userId: "alice", createdAt: Date(timeIntervalSince1970: 2_000))

        // 直接写入一个 active == nil 的 blob，模拟旧版本/异常数据
        let payload = SessionPayload(schemaVersion: 1, sessions: [old, new], active: nil)
        let data = try JSONEncoder().encode(payload)
        try secure.save(data, account: SessionStore.sessionsAccount, service: SessionStore.defaultService)

        #expect(try await store.active() == new)
    }

    @Test("删光所有会话后 active() 回到 nil")
    func activeIsNilAfterRemovingEverything() async throws {
        let (store, _) = makeStore()
        try await store.save(makeSession())

        try await store.removeAll()

        #expect(try await store.active() == nil)
        #expect(try await store.loadAll().isEmpty)
    }

    // MARK: 登出 / 失效

    @Test("markLoggedOut 清掉该服务器的会话，其他服务器不受影响")
    func markLoggedOutOnlyClearsTargetServer() async throws {
        let (store, _) = makeStore()
        try await store.save(makeSession(serverId: "srv-a", userId: "alice"))
        try await store.save(makeSession(serverId: "srv-b", userId: "alice"))

        try await store.markLoggedOut(serverId: "srv-a")

        #expect(try await store.session(serverId: "srv-a", userId: "alice") == nil)
        #expect(try await store.session(serverId: "srv-b", userId: "alice") != nil)
    }

    @Test("removeAll 清空存储里的条目本身")
    func removeAllClearsUnderlyingStore() async throws {
        let (store, secure) = makeStore()
        try await store.save(makeSession())

        try await store.removeAll()

        #expect(secure.count == 0)
        #expect(try await store.loadAll().isEmpty)
    }

    // MARK: 边界

    @Test("空字符串 token 能原样往返（是否可用由上层判断）")
    func emptyTokenRoundTrip() async throws {
        let (store, _) = makeStore()
        let session = makeSession(token: "")

        try await store.save(session)
        let loaded = try await store.loadAll().first

        #expect(loaded?.accessToken == "")
        #expect(loaded == session)
        // 空 token 不算有效会话，但存储层不替上层做这个判断
        #expect(loaded?.isValid == false)
    }

    @Test("10KB 超长 token 能完整往返")
    func longTokenRoundTrip() async throws {
        let (store, _) = makeStore()
        let token = String(repeating: "a1B2c3", count: 1_800)  // 10,800 字节
        let session = makeSession(token: token)

        try await store.save(session)
        let loaded = try await store.loadAll().first

        #expect(loaded?.accessToken.count == token.count)
        #expect(loaded?.accessToken == token)
    }

    @Test("含 emoji / 换行 / 引号的服务器名与用户名能正确往返")
    func specialCharactersRoundTrip() async throws {
        let (store, _) = makeStore()
        let session = makeSession(
            serverId: "srv-🎬-中文",
            userId: "user-\n-newline",
            userName: "客厅 \"Emby\" 🍿\n第二行"
        )

        try await store.save(session)
        let loaded = try await store.loadAll().first

        #expect(loaded?.serverId == "srv-🎬-中文")
        #expect(loaded?.userId == "user-\n-newline")
        #expect(loaded?.user.name == "客厅 \"Emby\" 🍿\n第二行")
    }

    // MARK: 损坏与失败

    @Test("blob 损坏时抛 decoding，而不是静默当作未登录")
    func corruptedBlobThrows() async throws {
        let (store, secure) = makeStore()
        try secure.save(
            Data("这不是 JSON".utf8),
            account: SessionStore.sessionsAccount,
            service: SessionStore.defaultService
        )

        await #expect(throws: SessionStoreError.self) {
            _ = try await store.loadAll()
        }
    }

    @Test("更高版本的存储格式视为不兼容并抛 decoding")
    func futureSchemaVersionThrows() async throws {
        let (store, secure) = makeStore()
        let payload = SessionPayload(schemaVersion: 99, sessions: [], active: nil)
        try secure.save(
            try JSONEncoder().encode(payload),
            account: SessionStore.sessionsAccount,
            service: SessionStore.defaultService
        )

        await #expect(throws: SessionStoreError.self) {
            _ = try await store.loadAll()
        }
    }

    @Test("底层 Keychain 报错会原样冒泡，不被吞掉")
    func secureStoreFailurePropagates() async throws {
        let failing = FailingSecureStore(error: .keychain(status: -25308, operation: .copy))
        let store = SessionStore(secureStore: failing)

        await #expect(throws: SessionStoreError.keychain(status: -25308, operation: .copy)) {
            _ = try await store.loadAll()
        }
    }

    @Test("自定义 service 与默认 service 的数据互相隔离")
    func customServiceIsIsolated() async throws {
        let secure = InMemorySecureStore()
        let first = SessionStore(secureStore: secure, service: "app.prism.Prism.tests.a")
        let second = SessionStore(secureStore: secure, service: "app.prism.Prism.tests.b")

        try await first.save(makeSession(serverId: "srv-a"))

        #expect(try await first.loadAll().count == 1)
        #expect(try await second.loadAll().isEmpty)
    }
}

/// 总是抛错的存储实现，用来验证错误路径。
private final class FailingSecureStore: SecureStoring, @unchecked Sendable {
    private let error: SessionStoreError

    init(error: SessionStoreError) {
        self.error = error
    }

    func save(_ data: Data, account: String, service: String) throws {
        throw error
    }

    func load(account: String, service: String) throws -> Data? {
        throw error
    }

    func delete(account: String, service: String) throws {
        throw error
    }

    func deleteAll(service: String) throws {
        throw error
    }
}
