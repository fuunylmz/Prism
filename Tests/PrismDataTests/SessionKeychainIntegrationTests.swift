import Foundation
import Testing
@testable import PrismData

/// 真实 Keychain 的集成测试，**默认不执行**。
///
/// 为什么默认关掉：开发机上是 ad-hoc 签名，每次重建二进制都会让已存在条目的 ACL
/// 不再信任新二进制，读取时 macOS 会弹「Prism 想要访问钥匙串中的机密信息」对话框。
/// 本项目已经因为钥匙串弹窗出过三次事故，所以自动化测试一律走 ``InMemorySecureStore``。
///
/// 需要人工验证真实钥匙串行为时，显式打开：
///
/// ```bash
/// PRISM_KEYCHAIN_TESTS=1 swift test --filter KeychainIntegration
/// ```
///
/// 该用例使用随机 service 名，结束时删除自己写入的条目，不会留下垃圾。
@Suite("Keychain 集成（默认关闭）")
struct SessionKeychainIntegrationTests {
    /// 环境变量开关。
    private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["PRISM_KEYCHAIN_TESTS"] == "1"
    }

    @Test(
        "真实 Keychain 增删改查往返",
        .enabled(if: SessionKeychainIntegrationTests.isEnabled)
    )
    func realKeychainRoundTrip() throws {
        let service = "app.prism.Prism.tests.\(UUID().uuidString)"
        let account = "probe"
        let store = KeychainSecureStore()
        defer {
            // 无论断言是否失败都清掉，避免污染用户的登录钥匙串
            try? store.deleteAll(service: service)
        }

        // 初始为空
        #expect(try store.load(account: account, service: service) == nil)

        // 新增
        let first = Data("token-1".utf8)
        try store.save(first, account: account, service: service)
        #expect(try store.load(account: account, service: service) == first)

        // 覆盖（走 SecItemUpdate 分支）
        let second = Data("token-2".utf8)
        try store.save(second, account: account, service: service)
        #expect(try store.load(account: account, service: service) == second)

        // 删除后回到 nil
        try store.delete(account: account, service: service)
        #expect(try store.load(account: account, service: service) == nil)

        // 删除不存在的条目不应抛错
        try store.delete(account: account, service: service)

        // 记录实际生效的钥匙串实现，便于人工确认降级是否发生
        if let kind = store.resolvedKind {
            print("[integration] 实际使用的钥匙串实现：\(kind)")
        }
    }
}
