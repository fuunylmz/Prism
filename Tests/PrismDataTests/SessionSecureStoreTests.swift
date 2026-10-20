import Foundation
import Testing
@testable import PrismData

/// ``InMemorySecureStore`` 的增删改查。
///
/// 这一组测试同时充当「``SecureStoring`` 语义契约」的说明书：
/// 找不到返回 `nil`、删除幂等、`deleteAll` 只清指定 service。
/// 生产实现 ``KeychainSecureStore`` 必须遵守同一套语义——**但绝不在这里验证**：
/// 真实 Keychain 在开发机上会弹授权对话框（本项目已出过三次事故），
/// 需要验证真机行为时请跑 `SessionKeychainIntegrationTests`（默认关闭）。
@Suite("SecureStore（内存实现）")
struct SessionSecureStoreTests {
    @Test("保存后能读回同样的字节")
    func saveAndLoad() throws {
        let store = InMemorySecureStore()
        let payload = Data("hello 世界".utf8)

        try store.save(payload, account: "alice", service: "svc")
        let loaded = try store.load(account: "alice", service: "svc")

        #expect(loaded == payload)
    }

    @Test("覆盖写入只保留最新值")
    func overwrite() throws {
        let store = InMemorySecureStore()

        try store.save(Data("v1".utf8), account: "alice", service: "svc")
        try store.save(Data("v2".utf8), account: "alice", service: "svc")

        #expect(try store.load(account: "alice", service: "svc") == Data("v2".utf8))
        #expect(store.count == 1)
    }

    @Test("读不存在的条目返回 nil，而不是报错")
    func loadMissingReturnsNil() throws {
        let store = InMemorySecureStore()

        #expect(try store.load(account: "nobody", service: "svc") == nil)
    }

    @Test("删除后读不到；重复删除不报错（幂等）")
    func deleteIsIdempotent() throws {
        let store = InMemorySecureStore()
        try store.save(Data("x".utf8), account: "alice", service: "svc")

        try store.delete(account: "alice", service: "svc")
        #expect(try store.load(account: "alice", service: "svc") == nil)
        #expect(store.count == 0)

        // 再删一次不应抛错
        try store.delete(account: "alice", service: "svc")
    }

    @Test("deleteAll 只清指定 service，别的 service 不受影响")
    func deleteAllScopedByService() throws {
        let store = InMemorySecureStore()
        try store.save(Data("a".utf8), account: "alice", service: "svc.a")
        try store.save(Data("b".utf8), account: "bob", service: "svc.a")
        try store.save(Data("c".utf8), account: "alice", service: "svc.b")

        try store.deleteAll(service: "svc.a")

        #expect(try store.load(account: "alice", service: "svc.a") == nil)
        #expect(try store.load(account: "bob", service: "svc.a") == nil)
        #expect(try store.load(account: "alice", service: "svc.b") == Data("c".utf8))
        #expect(store.count == 1)
    }

    @Test("同一 account 在不同 service 下互不干扰")
    func serviceIsolatesAccounts() throws {
        let store = InMemorySecureStore()
        try store.save(Data("one".utf8), account: "alice", service: "svc.1")
        try store.save(Data("two".utf8), account: "alice", service: "svc.2")

        #expect(try store.load(account: "alice", service: "svc.1") == Data("one".utf8))
        #expect(try store.load(account: "alice", service: "svc.2") == Data("two".utf8))
    }

    @Test("空 account / 空 service 直接拒绝，避免误伤整片条目")
    func rejectsEmptyKeys() {
        let store = InMemorySecureStore()

        #expect(throws: SessionStoreError.invalidValue("account 不能为空")) {
            try store.save(Data(), account: "", service: "svc")
        }
        #expect(throws: SessionStoreError.invalidValue("service 不能为空")) {
            try store.save(Data(), account: "alice", service: "")
        }
        #expect(throws: SessionStoreError.invalidValue("service 不能为空")) {
            try store.deleteAll(service: "")
        }
    }

    @Test("reset 清空全部条目（测试专用）")
    func resetClearsEverything() throws {
        let store = InMemorySecureStore()
        try store.save(Data("a".utf8), account: "alice", service: "svc.1")
        try store.save(Data("b".utf8), account: "alice", service: "svc.2")

        store.reset()

        #expect(store.count == 0)
        #expect(try store.load(account: "alice", service: "svc.1") == nil)
    }
}
