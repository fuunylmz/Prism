import Foundation

// MARK: - 错误

/// 会话持久化层的错误。
///
/// **为什么不复用 `EmbyError`**
///
/// 1. 语义不同：``EmbyError`` 的每个 case 都对应一种「与服务器交互」的结果
///    （401 / 超时 / 解码失败…），UI 会把它翻译成「服务器连不上」。而本地存储失败是
///    **本机故障**，既不该提示用户去检查网络，也不该触发登出。
/// 2. 判定会被污染：`EmbyError.requiresSignOut` 只看 `.unauthorized`，把存储错误塞进
///    `.unknown` 虽然不会误触发登出，但反过来——如果哪天有人为了「省事」把「文件不存在」
///    映射成 `.notFound`——就会走进完全错误的处理分支。
/// 3. 文件系统错误码是排障的唯一线索：`NSFileWriteNoPermissionError`（没权限）、
///    `NSFileNoSuchFileError`（目录被删）、磁盘满，在真机上是完全不同的处置方式，
///    而 `EmbyError.unknown(String)` 会把数字丢掉。
public enum SessionStoreError: Error, Sendable, Equatable, Hashable {
    /// 文件读写失败。
    ///
    /// - Parameters:
    ///   - code: 原始 `NSError.code`（`CocoaError` 域）。
    ///   - operation: 出错的步骤。
    case file(code: Int, operation: FileOperation)

    /// 序列化失败（`JSONEncoder` 抛错，正常不会发生，兜底保留）。
    case encoding(String)

    /// 读到的字节不是本层写入的格式（数据损坏 / 版本不兼容）。
    case decoding(String)

    /// 调用参数非法，例如空的 `account` 或 `service`。
    case invalidValue(String)

    /// 目标会话不存在（`setActive` / `remove` 指向了没保存过的会话）。
    case sessionNotFound(serverId: String, userId: String)
}

/// 文件操作的种类，把失败定位到具体一步。
public enum FileOperation: String, Sendable, Hashable {
    /// 读文件。
    case read
    /// 写文件。
    case write
    /// 删文件。
    case delete
}

extension SessionStoreError {
    /// 面向用户的本地化文案。
    ///
    /// 与 ``EmbyError/userMessage`` 保持同样的写法（key + 中文默认值），
    /// 待 `.xcstrings` 落地后直接建条目即可，调用点无需改动。
    public var userMessage: LocalizedStringResource {
        switch self {
        case .file:
            LocalizedStringResource(
                "error.sessionStore.file",
                defaultValue: "无法保存登录信息到本机，请检查磁盘空间。",
                comment: "EN: Unable to save sign-in information locally. Check disk space."
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
    /// 只有「临时性 IO 失败」可重试；数据损坏必须重新登录才能修复。
    public var isRecoverable: Bool {
        switch self {
        case let .file(_, operation):
            // 写入 / 删除失败通常是暂时性的（磁盘忙、目录刚被重建），
            // 读取失败多半意味着文件损坏，重试也没用。
            return operation != .read
        case .encoding, .decoding, .invalidValue, .sessionNotFound:
            return false
        }
    }

    /// 原始错误码（非文件错误为 `nil`），供日志使用。
    public var statusCode: Int? {
        if case let .file(code, _) = self { return code }
        return nil
    }
}

// MARK: - 协议

/// 本地存储抽象：把「字节 + 账号 + 服务名」三元组持久化到本机。
///
/// 抽成协议的目的是**让单测完全不碰真实磁盘**：生产环境写文件，
/// 单测注入 ``InMemorySecureStore``，测试之间互不影响，也不会污染用户的登录态。
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
    ///   - account: 条目账号。
    ///   - service: 条目服务名。
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

// MARK: - 文件实现

/// 把条目存成 JSON 文件的生产实现。
///
/// ## 为什么不用钥匙串
///
/// 早期版本把登录 token 放进 macOS 钥匙串（`SecItem`）。在**沙盒 + ad-hoc 签名**
/// （本工程当前的分发方式，见 `docs/BUILD_ENV.md`）下，数据保护钥匙串需要
/// provisioning profile 授权 `keychain-access-groups`，否则 `SecItemAdd` 返回
/// `errSecMissingEntitlement`(-34018)；回退到文件型钥匙串又受沙盒限制，且首次
/// 读取会弹「Prism 想要访问钥匙串中的机密信息」授权框。结果是**登录状态永远存不下来、
/// 每次打开都要重新登录**，而用户看到的是一连串系统弹窗。
///
/// 因此改为直接写应用自己的容器目录：无弹窗、无 entitlement 依赖、行为完全确定。
///
/// ## 安全边界（明确说明，不拔高）
///
/// - **不保存密码**。存的是 Emby 的 access token（免登录凭据），有效期由服务器控制，
///   用户改密码或在服务器端吊销后立即失效。
/// - 文件位于 app 容器内（`~/Library/Containers/<bundle id>/Data/Library/Application Support/`），
///   沙盒保证其它 App 读不到；同一台机器上拥有你用户账号的进程理论上可读。
/// - 因此定位是「本机便利性优先」。若将来需要在共用电脑上更强隔离，
///   可以改回钥匙串（需 Developer ID + provisioning profile），或干脆不提供「记住我」。
///
/// ## 存储形态
///
/// `Application Support/Prism/Session/<service>/<account>.json`，一个条目一个文件。
/// 用文件而不是一个大 JSON：切换服务器、删除某一台时不需要重写全部数据，
/// 也避免「写一半崩了导致所有会话丢失」。
public final class FileSecureStore: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let rootDirectory: URL

    /// 创建文件存储。
    ///
    /// - Parameter rootDirectory: 数据根目录；默认在应用支持目录下建 `Prism/Session`。
    ///   测试可传临时目录，避免污染真实数据。
    public init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory()
    }

    /// 默认根目录：`Application Support/Prism/Session`。
    ///
    /// - Returns: 根目录 URL。取不到应用支持目录时退回临时目录（仍可用，只是重启后丢失）。
    private static func defaultRootDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("Prism", isDirectory: true)
            .appendingPathComponent("Session", isDirectory: true)
    }

    // MARK: SecureStoring

    /// 写入或覆盖一条数据（原子写）。
    ///
    /// - Parameters:
    ///   - data: 待写入的字节。
    ///   - account: 条目账号。
    ///   - service: 条目服务名。
    /// - Throws: ``SessionStoreError``。
    public func save(_ data: Data, account: String, service: String) throws {
        try Self.validate(account: account, service: service)

        lock.lock()
        defer { lock.unlock() }

        do {
            try FileManager.default.createDirectory(
                at: directory(for: service),
                withIntermediateDirectories: true
            )
            // `.atomic`：先写临时文件再改名，避免「写一半断电」留下半个 JSON。
            try data.write(to: fileURL(account: account, service: service), options: .atomic)
        } catch {
            throw Self.storeError(error, operation: .write)
        }
    }

    /// 读取一条数据；文件不存在返回 `nil`。
    ///
    /// - Parameters:
    ///   - account: 条目账号。
    ///   - service: 条目服务名。
    /// - Returns: 已保存的字节；不存在时为 `nil`。
    /// - Throws: ``SessionStoreError``。
    public func load(account: String, service: String) throws -> Data? {
        try Self.validate(account: account, service: service)

        lock.lock()
        defer { lock.unlock() }

        let url = fileURL(account: account, service: service)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw Self.storeError(error, operation: .read)
        }
    }

    /// 删除一条数据（幂等）。
    ///
    /// - Parameters:
    ///   - account: 条目账号。
    ///   - service: 条目服务名。
    /// - Throws: ``SessionStoreError``。
    public func delete(account: String, service: String) throws {
        try Self.validate(account: account, service: service)

        lock.lock()
        defer { lock.unlock() }

        let url = fileURL(account: account, service: service)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw Self.storeError(error, operation: .delete)
        }
    }

    /// 删除某个 service 下的全部条目。
    ///
    /// - Parameter service: 条目服务名。
    /// - Throws: ``SessionStoreError``。
    public func deleteAll(service: String) throws {
        guard !service.isEmpty else {
            throw SessionStoreError.invalidValue("service 不能为空")
        }

        lock.lock()
        defer { lock.unlock() }

        let directory = directory(for: service)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            throw Self.storeError(error, operation: .delete)
        }
    }

    // MARK: 路径

    /// 某个 service 对应的目录。
    ///
    /// - Parameter service: 条目服务名。
    /// - Returns: 目录 URL。
    private func directory(for service: String) -> URL {
        rootDirectory.appendingPathComponent(Self.sanitize(service), isDirectory: true)
    }

    /// 某个条目的文件路径。
    ///
    /// - Parameters:
    ///   - account: 条目账号。
    ///   - service: 条目服务名。
    /// - Returns: 文件 URL。
    private func fileURL(account: String, service: String) -> URL {
        directory(for: service)
            .appendingPathComponent(Self.sanitize(account), isDirectory: false)
            .appendingPathExtension("json")
    }

    /// 把名字里可能构成路径的字符换掉，避免写到目录之外。
    ///
    /// - Parameter name: 原始名字。
    /// - Returns: 可安全用作文件名的字符串。
    private static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        return String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    // MARK: 内部

    /// 参数校验：空账号/空服务名会产生非法路径，必须拦住。
    private static func validate(account: String, service: String) throws {
        guard !account.isEmpty else {
            throw SessionStoreError.invalidValue("account 不能为空")
        }
        guard !service.isEmpty else {
            throw SessionStoreError.invalidValue("service 不能为空")
        }
    }

    /// 把任意 `Error` 归一化成 ``SessionStoreError``。
    ///
    /// - Parameters:
    ///   - error: 原始错误。
    ///   - operation: 出错的步骤。
    /// - Returns: 归一化后的错误。
    private static func storeError(_ error: any Error, operation: FileOperation) -> SessionStoreError {
        .file(code: (error as NSError).code, operation: operation)
    }
}

// MARK: - 测试 / 预览实现

/// 纯内存实现，供单元测试与预览使用。
///
/// 单测绝不碰真实磁盘：测试之间要互不影响，也不能污染用户的登录态。
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

    /// 参数校验，与 ``FileSecureStore`` 保持一致。
    private func validate(account: String, service: String) throws {
        guard !account.isEmpty else {
            throw SessionStoreError.invalidValue("account 不能为空")
        }
        guard !service.isEmpty else {
            throw SessionStoreError.invalidValue("service 不能为空")
        }
    }
}