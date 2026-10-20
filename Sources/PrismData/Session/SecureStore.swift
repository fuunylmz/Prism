import Foundation
import Security

// MARK: - 错误

/// Keychain 操作的种类，仅用于把失败状态码映射回「是哪一步炸的」。
public enum KeychainOperation: String, Sendable, Hashable {
    /// `SecItemAdd`
    case add
    /// `SecItemUpdate`
    case update
    /// `SecItemCopyMatching`
    case copy
    /// `SecItemDelete`
    case delete
}

/// 会话持久化层的错误。
///
/// **为什么不复用 `EmbyError`**
///
/// 1. 语义不同：``EmbyError`` 的每个 case 都对应一种「与服务器交互」的结果
///    （401 / 超时 / 解码失败…），UI 会把它翻译成「服务器连不上」。而 Keychain 失败是
///    **本机存储故障**，既不该提示用户去检查网络，也不该触发登出。
/// 2. 判定会被污染：`EmbyError.requiresSignOut` 只看 `.unauthorized`，把钥匙串错误塞进
///    `.unknown` 虽然不会误触发登出，但反过来——如果哪天有人为了「省事」把 -25300 映射成
///    `.notFound`——就会走进完全错误的处理分支。
/// 3. `OSStatus` 是排障的唯一线索：`-25300`（没找到）、`-25299`（已存在）、
///    `-34018`（缺 entitlement）、`-25308`（需要用户交互）在真机上是完全不同的处置方式，
///    而 `EmbyError.unknown(String)` 会把数字丢掉。
///
/// 因此这里单独立一个错误类型，并保留原始 `OSStatus`。
///
/// 状态码取值已对照本机 SDK 头文件核实
/// （`MacOSX.sdk/System/Library/Frameworks/Security.framework/Headers/SecBase.h`）：
/// `errSecDuplicateItem = -25299`、`errSecItemNotFound = -25300`、
/// `errSecInteractionNotAllowed = -25308`、`errSecMissingEntitlement = -34018`。
/// 官方语义：<https://developer.apple.com/documentation/security/errsecduplicateitem>、
/// <https://developer.apple.com/documentation/security/errsecitemnotfound>。
public enum SessionStoreError: Error, Sendable, Equatable, Hashable {
    /// Keychain 返回了非预期状态码。
    ///
    /// - Parameters:
    ///   - status: 原始 `OSStatus`（负数）。
    ///   - operation: 出错的 API。
    case keychain(status: OSStatus, operation: KeychainOperation)

    /// 序列化失败（`JSONEncoder` 抛错，正常不会发生，兜底保留）。
    case encoding(String)

    /// 读到的字节不是本层写入的格式（数据损坏 / 版本不兼容）。
    case decoding(String)

    /// 调用参数非法，例如空的 `account` 或 `service`。
    case invalidValue(String)

    /// 目标会话不存在（`setActive` / `remove` 指向了没保存过的会话）。
    case sessionNotFound(serverId: String, userId: String)
}

extension SessionStoreError {
    /// 面向用户的本地化文案。
    ///
    /// 与 ``EmbyError/userMessage`` 保持同样的写法（key + 中文默认值），
    /// 待 `.xcstrings` 落地后直接建条目即可，调用点无需改动。
    public var userMessage: LocalizedStringResource {
        switch self {
        case .keychain:
            LocalizedStringResource(
                "error.sessionStore.keychain",
                defaultValue: "无法安全地保存登录信息，请检查钥匙串是否已锁定。",
                comment: "EN: Unable to store sign-in information securely. Check that the keychain is unlocked."
            )
        case .encoding, .decoding:
            LocalizedStringResource(
                "error.sessionStore.dataCorrupted",
                defaultValue: "本地登录信息已损坏，请重新登录。",
                comment: "EN: The locally stored sign-in information is corrupted. Please sign in again."
            )
        case .invalidValue:
            LocalizedStringResource(
                "error.sessionStore.invalidValue",
                defaultValue: "登录信息不完整，请重新登录。",
                comment: "EN: The sign-in information is incomplete. Please sign in again."
            )
        case .sessionNotFound:
            LocalizedStringResource(
                "error.sessionStore.sessionNotFound",
                defaultValue: "找不到该登录会话，请重新登录。",
                comment: "EN: That sign-in session could not be found. Please sign in again."
            )
        }
    }

    /// 是否值得让用户重试。
    ///
    /// 只有「钥匙串被锁 / 需要交互」这类状态是暂时的；数据损坏必须重新登录才能修复。
    public var isRecoverable: Bool {
        switch self {
        case let .keychain(status, _):
            return status == errSecInteractionNotAllowed || status == errSecNotAvailable
        case .encoding, .decoding, .invalidValue, .sessionNotFound:
            return false
        }
    }

    /// 原始状态码（非 Keychain 错误为 `nil`），供日志使用。
    public var statusCode: OSStatus? {
        if case let .keychain(status, _) = self { return status }
        return nil
    }
}

// MARK: - 协议

/// 安全存储抽象：把「字节 + 账号 + 服务名」三元组放进系统钥匙串。
///
/// 抽成协议的唯一目的是**让单测完全不碰真实 Keychain**。
/// 真实 Keychain 在开发机上会弹出授权对话框（尤其是 ad-hoc 签名每次重建都会让
/// 旧条目的 ACL 失配），这是本项目明令禁止在测试里触发的事故模式。
/// 因此生产代码只依赖本协议，单测注入 ``InMemorySecureStore``。
///
/// 语义约定（实现方必须遵守）：
/// - `load` 找不到条目时返回 `nil`，**不是错误**。
/// - `delete` 删除不存在的条目视为成功（幂等）。
/// - `deleteAll(service:)` 只清该 service 下的条目。
public protocol SecureStoring: Sendable {
    /// 写入或覆盖一条数据。
    ///
    /// - Parameters:
    ///   - data: 待写入的字节。
    ///   - account: 条目账号（`kSecAttrAccount`）。
    ///   - service: 条目服务名（`kSecAttrService`）。
    /// - Throws: ``SessionStoreError``。
    func save(_ data: Data, account: String, service: String) throws

    /// 读取一条数据。
    ///
    /// - Parameters:
    ///   - account: 条目账号。
    ///   - service: 条目服务名。
    /// - Returns: 已保存的字节；不存在时为 `nil`。
    /// - Throws: ``SessionStoreError``。
    func load(account: String, service: String) throws -> Data?

    /// 删除一条数据（幂等）。
    ///
    /// - Parameters:
    ///   - account: 条目账号。
    ///   - service: 条目服务名。
    /// - Throws: ``SessionStoreError``。
    func delete(account: String, service: String) throws

    /// 删除某个 service 下的全部条目。
    ///
    /// - Parameter service: 条目服务名。
    /// - Throws: ``SessionStoreError``。
    func deleteAll(service: String) throws
}

// MARK: - 真实实现

/// Keychain 的可访问性等级。
///
/// 只暴露本项目真正需要的两档，避免把 `kSecAttrAccessible*` 的十来个常量泄漏到业务层。
///
/// **为什么不是 `WhenUnlocked`**：`WhenUnlocked` 在设备锁屏后条目不可读，
/// 后台任务（进度补报、下载续传）会静默失败；Apple 明确建议需要后台访问的条目用
/// `AfterFirstUnlock`：<https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlock>
/// （"This is recommended for items that need to be accessed by background applications."）。
///
/// **为什么默认带 `ThisDeviceOnly`**：`docs/research/macos-engineering.md` §5.3 规定
/// token 不随 iCloud 钥匙串同步、不随备份迁移到新设备（token 是设备绑定的，
/// 跨设备同步只增加泄露面）。若将来确实需要「换机后免登录」，把构造参数改成
/// ``afterFirstUnlock`` 即可。
public enum KeychainAccessibility: Sendable, Hashable {
    /// 首次解锁后可读，随加密备份迁移。
    case afterFirstUnlock
    /// 首次解锁后可读，**不**迁移、**不**同步（默认）。
    case afterFirstUnlockThisDeviceOnly

    /// 对应的 `kSecAttrAccessible*` 常量。
    var constant: CFString {
        switch self {
        case .afterFirstUnlock:
            return kSecAttrAccessibleAfterFirstUnlock
        case .afterFirstUnlockThisDeviceOnly:
            return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
    }
}

/// 使用哪一种 macOS 钥匙串实现。
///
/// macOS 有**两套**钥匙串实现，`SecItem` API 都能访问（
/// <https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains>）：
///
/// | 实现 | 访问控制 | 是否需要 entitlement | 默认 |
/// |---|---|---|---|
/// | 文件型（`login.keychain-db`） | ACL（`SecAccess`） | 否 | 是（`SecItem` 的默认目标） |
/// | 数据保护型（DP，iOS 同款） | Keychain access group | **是** | 需显式打开 |
///
/// Apple 推荐用 DP 钥匙串（跨平台语义一致、支持 iCloud 钥匙串、访问控制模型更清晰），
/// 打开方式是查询字典里加 `kSecUseDataProtectionKeychain: true`：
/// <https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain>
/// （"It's highly recommended that you set the value of this key to true for all keychain operations."）。
///
/// **但 DP 钥匙串的 access group 来自代码签名 entitlement**（`application-identifier`
/// 或 `keychain-access-groups`，且必须由 provisioning profile 授权）。本工程当前是
/// **ad-hoc 签名**（`docs/BUILD_ENV.md` §6：本机 0 个有效签名身份，只能用 `-`），
/// 既没有 team id 也没有内嵌 profile，此时 DP 钥匙串会返回
/// `errSecMissingEntitlement`（-34018）。这是社区反复踩到的事实：
/// <https://developer.apple.com/forums/thread/114456>
/// （"If you're using the traditional file-based keychain, you should never see error -34018."）。
///
/// 因此默认用 ``automatic``：先按 Apple 推荐走 DP，一旦拿到 -34018 / -50（参数不支持）
/// 就**自动降级**到文件型钥匙串，并在本进程内记住结果。等 M5 接上 Developer ID +
/// provisioning profile 后，DP 路径会自动生效，不需要改业务代码。
public enum KeychainKind: Sendable, Hashable {
    /// 数据保护钥匙串（iOS 同款语义）。
    case dataProtection
    /// 文件型钥匙串（`login.keychain-db`）。
    case fileBased
    /// 先试数据保护，缺 entitlement 时降级到文件型（默认）。
    case automatic
}

/// 基于 `Security.framework` 的真实实现。
///
/// 线程安全：所有方法都可以从任意线程/actor 调用；内部只用一个锁保护「已解析的钥匙串实现」
/// 这一小块可变状态，Keychain 调用本身**不持锁**（避免串行化慢操作）。
public final class KeychainSecureStore: SecureStoring, @unchecked Sendable {
    /// 首选实现。
    private let preferredKind: KeychainKind
    /// 条目的可访问性（仅在数据保护钥匙串下生效，见下）。
    private let accessibility: KeychainAccessibility
    /// 保护 ``resolvedKindStorage`` 的锁。
    private let lock = NSLock()
    /// 首次成功调用后确定的实现；`nil` 表示还没解析过。
    private var resolvedKindStorage: KeychainKind?

    /// 创建实例。
    ///
    /// - Parameters:
    ///   - kind: 钥匙串实现，默认 ``KeychainKind/automatic``。
    ///   - accessibility: 可访问性等级，默认 ``KeychainAccessibility/afterFirstUnlockThisDeviceOnly``。
    ///
    /// - Note: `kSecAttrAccessible` 在 macOS 上**只有在数据保护钥匙串下才生效**，
    ///   官方原文："You can use this attribute for macOS keychain items only if you also set
    ///   a value of `true` for the `kSecUseDataProtectionKeychain` key"
    ///   —— <https://developer.apple.com/documentation/security/ksecattraccessible>。
    ///   所以文件型钥匙串分支里刻意**不带**这个属性：带上会被当成不匹配的查询条件，
    ///   导致「刚写进去却读不出来」。
    public init(
        kind: KeychainKind = .automatic,
        accessibility: KeychainAccessibility = .afterFirstUnlockThisDeviceOnly
    ) {
        self.preferredKind = kind
        self.accessibility = accessibility
    }

    /// 实际生效的钥匙串实现；尚未发生任何调用时为 `nil`。
    public var resolvedKind: KeychainKind? {
        lock.lock()
        defer { lock.unlock() }
        return resolvedKindStorage
    }

    /// 写入或覆盖一条数据。
    ///
    /// 冲突处理：`SecItemAdd` 撞到已存在条目时返回 `errSecDuplicateItem`（-25299），
    /// 官方说明它按「主键」判重（generic password 的主键是
    /// `kSecAttrAccount` + `kSecAttrService`）：
    /// <https://developer.apple.com/documentation/security/errsecduplicateitem>。
    ///
    /// 这里的处置顺序是 **add → update →（条目在两次调用之间消失时）add**：
    /// 相比「先 delete 再 add」，update 是原子的，不会出现「删掉了但加不回去」的丢数据窗口，
    /// 也保留了条目原有的 ACL / 可访问性。删除只是最后的兜底路径，不会静默丢数据。
    public func save(_ data: Data, account: String, service: String) throws {
        try Self.validate(account: account, service: service)

        try perform { kind in
            var addQuery = self.baseQuery(account: account, service: service, kind: kind)
            addQuery[kSecValueData as String] = data
            if kind == .dataProtection {
                addQuery[kSecAttrAccessible as String] = self.accessibility.constant
            }

            var status = SecItemAdd(addQuery as CFDictionary, nil)
            if status == errSecDuplicateItem {
                let matchQuery = self.baseQuery(account: account, service: service, kind: kind)
                var attributes: [String: Any] = [kSecValueData as String: data]
                if kind == .dataProtection {
                    attributes[kSecAttrAccessible as String] = self.accessibility.constant
                }
                status = SecItemUpdate(matchQuery as CFDictionary, attributes as CFDictionary)
                if status == errSecItemNotFound {
                    // 极小概率：条目在 add 与 update 之间被别的进程删了。补一次 add。
                    status = SecItemAdd(addQuery as CFDictionary, nil)
                }
            }

            guard status == errSecSuccess else {
                throw SessionStoreError.keychain(status: status, operation: .add)
            }
        }
    }

    /// 读取一条数据；条目不存在返回 `nil`。
    ///
    /// `errSecItemNotFound`（-25300）是「没找到」而不是失败，
    /// 见 <https://developer.apple.com/documentation/security/errsecitemnotfound>。
    public func load(account: String, service: String) throws -> Data? {
        try Self.validate(account: account, service: service)

        return try perform { kind in
            var query = self.baseQuery(account: account, service: service, kind: kind)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            switch status {
            case errSecSuccess:
                guard let data = item as? Data else {
                    throw SessionStoreError.decoding("Keychain 返回的条目不是 Data")
                }
                return data
            case errSecItemNotFound:
                return nil
            default:
                throw SessionStoreError.keychain(status: status, operation: .copy)
            }
        }
    }

    /// 删除一条数据（幂等）。
    public func delete(account: String, service: String) throws {
        try Self.validate(account: account, service: service)

        try perform { kind in
            let query = self.baseQuery(account: account, service: service, kind: kind)
            let status = SecItemDelete(query as CFDictionary)
            switch status {
            case errSecSuccess, errSecItemNotFound:
                return
            default:
                throw SessionStoreError.keychain(status: status, operation: .delete)
            }
        }
    }

    /// 删除某个 service 下的全部条目。
    public func deleteAll(service: String) throws {
        guard !service.isEmpty else {
            throw SessionStoreError.invalidValue("service 不能为空")
        }

        try perform { kind in
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service
            ]
            if kind == .dataProtection {
                query[kSecUseDataProtectionKeychain as String] = true
            }
            let status = SecItemDelete(query as CFDictionary)
            switch status {
            case errSecSuccess, errSecItemNotFound:
                return
            default:
                throw SessionStoreError.keychain(status: status, operation: .delete)
            }
        }
    }

    // MARK: 内部

    /// 参数校验：空账号/空服务名会让查询退化成「匹配一大片条目」，必须拦住。
    private static func validate(account: String, service: String) throws {
        guard !account.isEmpty else {
            throw SessionStoreError.invalidValue("account 不能为空")
        }
        guard !service.isEmpty else {
            throw SessionStoreError.invalidValue("service 不能为空")
        }
    }

    /// 构造通用密码条目的基础查询字典。
    private func baseQuery(account: String, service: String, kind: KeychainKind) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if kind == .dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    /// 按已解析（或待解析）的钥匙串实现执行一次操作，必要时自动降级。
    ///
    /// 降级条件只认「缺 entitlement」这一类：`errSecMissingEntitlement`（-34018）与
    /// `errSecParam`（-50，文件型钥匙串不支持某个属性时的表现）。其它错误原样抛出，
    /// 免得把「用户取消了授权」误判成「环境不支持」而悄悄换库。
    private func perform<T>(_ operation: (KeychainKind) throws -> T) throws -> T {
        if let resolved = resolvedKind {
            return try operation(resolved)
        }

        switch preferredKind {
        case .dataProtection, .fileBased:
            lock.lock()
            resolvedKindStorage = preferredKind
            lock.unlock()
            return try operation(preferredKind)

        case .automatic:
            do {
                let result = try operation(.dataProtection)
                lock.lock()
                resolvedKindStorage = .dataProtection
                lock.unlock()
                return result
            } catch let error as SessionStoreError where Self.isUnsupportedInThisEnvironment(error) {
                lock.lock()
                resolvedKindStorage = .fileBased
                lock.unlock()
                return try operation(.fileBased)
            }
        }
    }

    /// 判断错误是否属于「当前签名环境下根本用不了数据保护钥匙串」。
    private static func isUnsupportedInThisEnvironment(_ error: SessionStoreError) -> Bool {
        guard let status = error.statusCode else { return false }
        return status == errSecMissingEntitlement || status == errSecParam
    }
}

// MARK: - 测试实现

/// 纯内存实现，供单元测试与预览使用。
///
/// **单测绝不能碰真实 Keychain**：开发机上 ad-hoc 签名每次重建都会变，旧条目的 ACL
/// 不再信任新二进制，读取时会弹「Prism 想要访问钥匙串中的机密信息」对话框。
/// 本项目已经因为钥匙串弹窗出过三次事故，所以测试一律注入本类型。
public final class InMemorySecureStore: SecureStoring, @unchecked Sendable {
    /// `(service, account)` → 字节。
    private struct Slot: Hashable {
        let service: String
        let account: String
    }

    private let lock = NSLock()
    private var storage: [Slot: Data] = [:]

    /// 创建空存储。
    public init() {}

    /// 当前保存的条目数（测试断言用）。
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    /// 清空全部条目（测试用）。
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }

    /// 写入或覆盖。
    public func save(_ data: Data, account: String, service: String) throws {
        try validate(account: account, service: service)
        lock.lock()
        defer { lock.unlock() }
        storage[Slot(service: service, account: account)] = data
    }

    /// 读取；不存在返回 `nil`。
    public func load(account: String, service: String) throws -> Data? {
        try validate(account: account, service: service)
        lock.lock()
        defer { lock.unlock() }
        return storage[Slot(service: service, account: account)]
    }

    /// 删除（幂等）。
    public func delete(account: String, service: String) throws {
        try validate(account: account, service: service)
        lock.lock()
        defer { lock.unlock() }
        storage[Slot(service: service, account: account)] = nil
    }

    /// 删除某个 service 下的全部条目。
    public func deleteAll(service: String) throws {
        guard !service.isEmpty else {
            throw SessionStoreError.invalidValue("service 不能为空")
        }
        lock.lock()
        defer { lock.unlock() }
        storage = storage.filter { $0.key.service != service }
    }

    /// 参数校验，与 ``KeychainSecureStore`` 保持一致。
    private func validate(account: String, service: String) throws {
        guard !account.isEmpty else {
            throw SessionStoreError.invalidValue("account 不能为空")
        }
        guard !service.isEmpty else {
            throw SessionStoreError.invalidValue("service 不能为空")
        }
    }
}
