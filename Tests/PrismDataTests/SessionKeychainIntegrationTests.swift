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

        // 记录实际生效的钥匙串实现，便于人工确认降级是否发生。
        // ad-hoc 签名 + 沙盒下应当是 `fileBased`：数据保护钥匙串会返回
        // -34018（缺 entitlement），必须回退，否则会话永远写不进去。
        let kind = try #require(store.resolvedKind, "解析后应当已有确定的实现")
        print("[integration] 实际使用的钥匙串实现：\(kind)")

        // 空库上的读取不能把实现「锁死」成数据保护——
        // 这正是「每次打开都要重新输入服务器」的成因。
        #expect(kind == .fileBased, "ad-hoc 签名环境下应回退到文件型钥匙串")
    }
}

// MARK: - 自动模式的实现解析

/// 「先写入探测、再锁定钥匙串实现」这条决策，**只能在真实钥匙串可用时验证**。
///
/// 为什么不做成默认执行的单测：
/// - 本项目的既定规则是「单测绝不碰真实 Keychain」（见文件顶部说明）；
/// - 而且开发/CI 环境常常在文件沙箱里跑测试，`SecItemAdd` 会直接返回
///   `100001`，任何依赖真实钥匙串的断言都会假失败。
///
/// 该决策守的是一条真实故障（用户反馈「每次打开都要重新输入服务器」）：
/// 空库上 `load` 走数据保护钥匙串返回 `errSecItemNotFound`，被当成「成功」后
/// 把实现锁死为 `.dataProtection`；随后真正的 `save` 返回 `-34018`
/// （沙盒 + ad-hoc 签名缺 entitlement），回退分支再也不会执行，会话永远写不进去。
///
/// 人工验证方法：在**没有文件沙箱**的终端里执行
///
/// ```bash
/// PRISM_KEYCHAIN_TESTS=1 swift test --filter KeychainIntegration
/// ```
///
/// 并观察输出里的「实际使用的钥匙串实现」——ad-hoc 签名下应当是 `fileBased`。
