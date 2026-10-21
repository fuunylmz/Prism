import Foundation
import Testing
@testable import PrismData

/// ``FileSecureStore``：生产环境的会话存储实现。
///
/// 为什么要单独测它：这是**真实写入用户磁盘**的那条路径。它取代了钥匙串
/// （沙盒 + ad-hoc 签名下钥匙串必然失败，导致每次打开都要重新登录），
/// 一旦回归，用户会立刻表现为「登录状态又没了」。
///
/// 测试全部在临时目录里跑，跑完删除，不碰用户的真实数据。
@Suite("FileSecureStore", .serialized)
struct FileSecureStoreTests {
    /// 造一个独立临时目录。
    private func makeTempRoot() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("prism-file-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let service = "app.prism.Prism"
    private let account = "sessions.v1"

    // MARK: 基本往返

    @Test("写入后能原样读回")
    func roundTrip() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileSecureStore(rootDirectory: root)
        let payload = Data("token-blob".utf8)

        try store.save(payload, account: account, service: service)

        #expect(try store.load(account: account, service: service) == payload)
    }

    @Test("没有条目时返回 nil 而不是抛错")
    func missingReturnsNil() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileSecureStore(rootDirectory: root)

        #expect(try store.load(account: account, service: service) == nil)
    }

    @Test("覆盖写入以最后一次为准")
    func overwrite() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileSecureStore(rootDirectory: root)

        try store.save(Data("first".utf8), account: account, service: service)
        try store.save(Data("second".utf8), account: account, service: service)

        #expect(try store.load(account: account, service: service) == Data("second".utf8))
    }

    @Test("删除后回到 nil，重复删除不抛错")
    func deleteIsIdempotent() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileSecureStore(rootDirectory: root)

        try store.save(Data("x".utf8), account: account, service: service)
        try store.delete(account: account, service: service)
        #expect(try store.load(account: account, service: service) == nil)

        // 幂等：再删一次不该抛。
        try store.delete(account: account, service: service)
    }

    @Test("deleteAll 只清指定 service，不误伤其它数据")
    func deleteAllIsScoped() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileSecureStore(rootDirectory: root)

        try store.save(Data("a".utf8), account: account, service: service)
        try store.save(Data("b".utf8), account: "other", service: "app.prism.Other")

        try store.deleteAll(service: service)

        #expect(try store.load(account: account, service: service) == nil)
        #expect(try store.load(account: "other", service: "app.prism.Other") == Data("b".utf8))
    }

    // MARK: 持久性（这正是原故障的核心）

    @Test("换一个实例仍能读到，模拟「重启 App 后免登录」")
    func survivesNewInstance() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("session".utf8)

        // 第一次运行：写入。
        try FileSecureStore(rootDirectory: root).save(payload, account: account, service: service)

        // 第二次运行：全新的实例，同一目录。
        let reopened = FileSecureStore(rootDirectory: root)
        #expect(try reopened.load(account: account, service: service) == payload)
    }

    // MARK: 安全性

    @Test("账号里的路径穿越字符会被消解，不会写到目录外")
    func sanitizesPathTraversal() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileSecureStore(rootDirectory: root)

        try store.save(Data("x".utf8), account: "../../evil", service: service)

        // 数据仍在 root 之内，没有逃逸到父目录。
        let escaped = root
            .deletingLastPathComponent()
            .appendingPathComponent("evil.json")
        #expect(!FileManager.default.fileExists(atPath: escaped.path))
        #expect(try store.load(account: "../../evil", service: service) == Data("x".utf8))
    }

    @Test("空账号或空服务名被拒绝")
    func rejectsEmptyNames() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileSecureStore(rootDirectory: root)

        #expect(throws: SessionStoreError.invalidValue("account 不能为空")) {
            try store.save(Data(), account: "", service: service)
        }
        #expect(throws: SessionStoreError.invalidValue("service 不能为空")) {
            try store.save(Data(), account: account, service: "")
        }
    }

    // MARK: 错误语义

    @Test("写入失败时抛出可识别的文件错误，而不是静默成功")
    func writeFailureSurfaces() throws {
        // 用一个「父路径是文件」的目录，让 createDirectory 必然失败。
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("prism-blocked-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: base)
        defer { try? FileManager.default.removeItem(at: base) }

        let store = FileSecureStore(rootDirectory: base)

        #expect(throws: SessionStoreError.self) {
            try store.save(Data("x".utf8), account: account, service: service)
        }
    }
}