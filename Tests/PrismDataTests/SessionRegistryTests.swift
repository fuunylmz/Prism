import Foundation
import Testing
import PrismCore
@testable import PrismData

/// ``ServerRegistry`` 的增删查、排序与持久化。
///
/// 每个用例都用**独立 suite** 的 `UserDefaults`，并在结束时 `removePersistentDomain`，
/// 绝不污染真实的 `.standard` 域（否则开发机的 Prism 偏好会被测试数据搞脏）。
@Suite("ServerRegistry", .serialized)
struct SessionRegistryTests {
    // MARK: 夹具

    /// 一次性的 `UserDefaults` 容器。
    private struct TestDefaults {
        let suiteName: String
        let defaults: UserDefaults

        init() throws {
            suiteName = "test.prism.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suiteName))
        }

        /// 从磁盘和内存里移除整个域。
        func cleanUp() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private func makeConnection(
        id: String,
        name: String = "Emby",
        host: String = "192.168.1.10",
        lastConnectedAt: Date? = nil
    ) throws -> ServerConnection {
        let url = try #require(URL(string: "http://\(host):8096"))
        return ServerConnection(id: id, name: name, baseURL: url, lastConnectedAt: lastConnectedAt)
    }

    // MARK: 查询

    @Test("初始为空")
    func startsEmpty() async throws {
        let fixture = try TestDefaults()
        defer { fixture.cleanUp() }
        let registry = ServerRegistry(defaults: fixture.defaults)

        #expect(await registry.servers().isEmpty)
        #expect(await registry.lastActiveServerId == nil)
        #expect(await registry.server(id: "nope") == nil)
    }

    @Test("upsert 新增后可按 id 查回")
    func upsertAndLookup() async throws {
        let fixture = try TestDefaults()
        defer { fixture.cleanUp() }
        let registry = ServerRegistry(defaults: fixture.defaults)
        let connection = try makeConnection(id: "srv-a", name: "客厅")

        await registry.upsert(connection)

        #expect(await registry.server(id: "srv-a") == connection)
        #expect(await registry.servers().count == 1)
    }

    @Test("同 id 的 upsert 是更新，不是追加")
    func upsertDeduplicatesById() async throws {
        let fixture = try TestDefaults()
        defer { fixture.cleanUp() }
        let registry = ServerRegistry(defaults: fixture.defaults)

        await registry.upsert(try makeConnection(id: "srv-a", name: "旧名字"))
        await registry.upsert(try makeConnection(id: "srv-a", name: "新名字"))

        let all = await registry.servers()
        #expect(all.count == 1)
        #expect(all.first?.name == "新名字")
    }

    @Test("排序：最近使用的排最前，从未连上的排最后")
    func sortsByRecentUse() async throws {
        let fixture = try TestDefaults()
        defer { fixture.cleanUp() }
        let registry = ServerRegistry(defaults: fixture.defaults)

        await registry.upsert(try makeConnection(id: "old", name: "Old", lastConnectedAt: Date(timeIntervalSince1970: 100)))
        await registry.upsert(try makeConnection(id: "never", name: "Never"))
        await registry.upsert(try makeConnection(id: "new", name: "New", lastConnectedAt: Date(timeIntervalSince1970: 900)))

        let ids = await registry.servers().map(\.id)
        #expect(ids == ["new", "old", "never"])
    }

    // MARK: 使用记录

    @Test("markUsed 更新连接时间并记住上次激活的服务器")
    func markUsedUpdatesTimeAndActive() async throws {
        let fixture = try TestDefaults()
        defer { fixture.cleanUp() }
        let registry = ServerRegistry(defaults: fixture.defaults)
        await registry.upsert(try makeConnection(id: "srv-a"))
        await registry.upsert(try makeConnection(id: "srv-b"))

        let stamp = Date(timeIntervalSince1970: 12_345)
        let found = await registry.markUsed(id: "srv-b", at: stamp)

        #expect(found)
        #expect(await registry.server(id: "srv-b")?.lastConnectedAt == stamp)
        #expect(await registry.lastActiveServerId == "srv-b")
        // 最近使用的排到最前
        #expect(await registry.servers().first?.id == "srv-b")
    }

    @Test("markUsed 指向未登记的服务器时返回 false 且不写入")
    func markUsedUnknownReturnsFalse() async throws {
        let fixture = try TestDefaults()
        defer { fixture.cleanUp() }
        let registry = ServerRegistry(defaults: fixture.defaults)

        let found = await registry.markUsed(id: "ghost")

        #expect(found == false)
        #expect(await registry.lastActiveServerId == nil)
    }

    @Test("setLastActiveServerId 可写可清")
    func setLastActiveServerId() async throws {
        let fixture = try TestDefaults()
        defer { fixture.cleanUp() }
        let registry = ServerRegistry(defaults: fixture.defaults)

        await registry.setLastActiveServerId("srv-a")
        #expect(await registry.lastActiveServerId == "srv-a")

        await registry.setLastActiveServerId(nil)
        #expect(await registry.lastActiveServerId == nil)

        // 空字符串等价于清除，避免存进一个无意义的 id
        await registry.setLastActiveServerId("")
        #expect(await registry.lastActiveServerId == nil)
    }

    // MARK: 删除

    @Test("remove 删掉指定服务器，其他保留")
    func removeOne() async throws {
        let fixture = try TestDefaults()
        defer { fixture.cleanUp() }
        let registry = ServerRegistry(defaults: fixture.defaults)
        await registry.upsert(try makeConnection(id: "srv-a"))
        await registry.upsert(try makeConnection(id: "srv-b"))

        await registry.remove(id: "srv-a")

        #expect(await registry.server(id: "srv-a") == nil)
        #expect(await registry.server(id: "srv-b") != nil)
        #expect(await registry.servers().count == 1)
    }

    @Test("删掉正好是「上次激活」的服务器时，标记一起清掉")
    func removeActiveClearsHint() async throws {
        let fixture = try TestDefaults()
        defer { fixture.cleanUp() }
        let registry = ServerRegistry(defaults: fixture.defaults)
        await registry.upsert(try makeConnection(id: "srv-a"))
        await registry.markUsed(id: "srv-a")

        await registry.remove(id: "srv-a")

        #expect(await registry.lastActiveServerId == nil)
    }

    @Test("remove 不存在的 id 不报错")
    func removeUnknownIsNoOp() async throws {
        let fixture = try TestDefaults()
        defer { fixture.cleanUp() }
        let registry = ServerRegistry(defaults: fixture.defaults)
        await registry.upsert(try makeConnection(id: "srv-a"))

        await registry.remove(id: "ghost")

        #expect(await registry.servers().count == 1)
    }

    @Test("removeAll 清空列表与激活标记")
    func removeAll() async throws {
        let fixture = try TestDefaults()
        defer { fixture.cleanUp() }
        let registry = ServerRegistry(defaults: fixture.defaults)
        await registry.upsert(try makeConnection(id: "srv-a"))
        await registry.markUsed(id: "srv-a")

        await registry.removeAll()

        #expect(await registry.servers().isEmpty)
        #expect(await registry.lastActiveServerId == nil)
    }

    // MARK: 持久化

    @Test("模拟重启：新实例从同一 suite 读回数据")
    func survivesInstanceRecreation() async throws {
        let fixture = try TestDefaults()
        defer { fixture.cleanUp() }
        let connection = try makeConnection(id: "srv-a", name: "书房")
        let stamp = Date(timeIntervalSince1970: 555)

        let first = ServerRegistry(defaults: fixture.defaults)
        await first.upsert(connection)
        await first.markUsed(id: "srv-a", at: stamp)

        let second = ServerRegistry(defaults: fixture.defaults)

        #expect(await second.servers().count == 1)
        #expect(await second.server(id: "srv-a")?.name == "书房")
        #expect(await second.server(id: "srv-a")?.lastConnectedAt == stamp)
        #expect(await second.lastActiveServerId == "srv-a")
    }

    @Test("数据损坏时退化为空列表，不抛错也不崩")
    func corruptedDataFallsBackToEmpty() async throws {
        let fixture = try TestDefaults()
        defer { fixture.cleanUp() }
        fixture.defaults.set(
            Data("这不是 JSON".utf8),
            forKey: ServerRegistry.defaultServersKey
        )
        let registry = ServerRegistry(defaults: fixture.defaults)

        #expect(await registry.servers().isEmpty)
        // 仍然可以继续写入，覆盖掉坏数据
        await registry.upsert(try makeConnection(id: "srv-a"))
        #expect(await registry.servers().count == 1)
    }

    @Test("自定义键名与默认键名互不干扰")
    func customKeysAreIsolated() async throws {
        let fixture = try TestDefaults()
        defer { fixture.cleanUp() }
        let custom = ServerRegistry(
            defaults: fixture.defaults,
            serversKey: "custom.servers",
            activeServerKey: "custom.active"
        )
        let standard = ServerRegistry(defaults: fixture.defaults)

        await custom.upsert(try makeConnection(id: "srv-a"))

        #expect(await custom.servers().count == 1)
        #expect(await standard.servers().isEmpty)
    }
}
