import Foundation
import PrismCore

// MARK: - 存储格式

/// 本机保存的凭据集合（一个 JSON 文件）。
///
/// **为什么把所有凭据 + active 标记放进一个文件**
///
/// 1. **原子性**：`save` + `setActive` 是两次独立的写。放进同一个 blob 时，
///    它们共享一次原子写（`.atomic` 先写临时文件再改名），中间崩溃不会留下
///    「凭据存了但 active 没更新」的半状态。
/// 2. **读取成本**：启动恢复只需要读一个文件，不必枚举目录再逐个读。
/// 3. **可版本化**：`schemaVersion` 就在 JSON 里，改结构时不需要迁移外部属性。
/// 4. **可替换**：``SecureStoring`` 把「怎么存」隔离掉了，换实现不必动 `CredentialStore`。
///
/// **代价（已权衡）**：单条 blob 损坏会一起丢。这靠 ``CredentialStore`` 的
/// 「解码失败 → 抛 `SessionStoreError.decoding`」让上层引导重新登录，
/// 而不是静默返回空数组假装未登录（那会掩盖 bug）。
struct CredentialPayload: Codable, Sendable, Equatable {
    /// 当前格式版本。读到更高版本视为不兼容。
    static let currentSchemaVersion = 1

    /// 格式版本。
    var schemaVersion: Int
    /// 全部凭据，**保持写入顺序**（新保存的追加在末尾）。
    var credentials: [StoredCredential]
    /// 上次激活的凭据标识；`nil` 表示没标记过。
    var active: CredentialKey?

    /// 空载荷。
    static var empty: CredentialPayload {
        CredentialPayload(schemaVersion: currentSchemaVersion, credentials: [], active: nil)
    }
}

/// 凭据标识：`serverId` + `userId` 的组合。
///
/// 不用拼接字符串作为持久化 key：一旦某个 serverId 或 userId 里出现冒号，
/// 拼接就会撞 key。分开存字段没有这个问题。
struct CredentialKey: Codable, Sendable, Hashable {
    /// 服务器 id。
    let serverId: String
    /// 用户 id。
    let userId: String
}

// MARK: - CredentialStore

/// 登录凭据持久化：保存「服务器 + 用户名 + 密码」，支持多服务器、多用户共存。
///
/// 典型用法：
///
/// ```swift
/// let store = CredentialStore(secureStore: FileSecureStore())
/// try await store.save(credential)                  // 登录成功后
/// let active = try await store.active()             // 启动时取回并重新登录
/// try await store.setActive(serverId: s, userId: u) // 切换服务器
/// try await store.markLoggedOut(serverId: s)        // 用户主动登出
/// ```
///
/// 设计要点：
/// - **存密码，不存 token**：token 会被服务器吊销、会过期，客户端无从预知；
///   每次启动用密码重新换取新 token，才不会出现「过一阵子又要重登」。
///   安全代价见 ``StoredCredential`` 的说明。
/// - **与服务器地址分开存**：地址、名称等非敏感信息归 ``ServerRegistry``
///   （`UserDefaults`）。分开的好处是换地址不必重登，清凭据也不该丢服务器列表。
/// - 存取是**一个 JSON blob**，理由见 ``CredentialPayload``。
/// - `actor`：所有调用串行化，避免「读-改-写」blob 时的竞态（例如同时登录两台服务器）。
public actor CredentialStore {
    /// 默认存储命名空间（决定文件落在哪个子目录）。
    public static let defaultService = "app.prism.Prism"

    /// 承载 blob 的账号名（决定文件名）。
    ///
    /// 只有一条记录，所以是个固定值而不是 serverId。带 `v1` 后缀是为了将来换存储格式时
    /// 能并存新旧两份数据（先读新、读不到再读旧，迁移完删旧），不必原地改格式。
    ///
    /// - Note: 名字用 `credentials` 而不是 `sessions`，是为了和旧版本（存 token）
    ///   的文件区分开——升级后旧文件不会被误读成新格式。
    static let credentialsAccount = "credentials.v1"

    /// 旧版本存 token 用的账号名；升级时用它做一次性清理。
    static let legacySessionsAccount = "sessions.v1"

    /// 底层本地存储。
    private let secureStore: any SecureStoring
    /// 存储命名空间。
    private let service: String

    /// 创建实例。
    ///
    /// - Parameters:
    ///   - secureStore: 本地存储实现。生产环境用 ``FileSecureStore``，
    ///     测试必须用 ``InMemorySecureStore``（见 ``SecureStoring`` 的说明）。
    ///   - service: 存储命名空间，默认 ``defaultService``。
    public init(secureStore: any SecureStoring, service: String = CredentialStore.defaultService) {
        self.secureStore = secureStore
        self.service = service
    }

    // MARK: 写入

    /// 保存（或覆盖）一条凭据。
    ///
    /// 同一 `serverId` + `userId` 视为同一条，重复保存会原位替换、不改变顺序。
    /// 若当前还没有 active 标记，新凭据会被自动设为 active——这样「刚登录完就重启」
    /// 也能免登录恢复，不需要调用方额外记得调 ``setActive(serverId:userId:)``。
    ///
    /// - Parameter credential: 待保存的凭据。
    /// - Throws: ``SessionStoreError``。
    public func save(_ credential: StoredCredential) throws {
        var payload = try loadPayload()

        let key = CredentialKey(serverId: credential.serverId, userId: credential.userId)
        if let index = payload.credentials.firstIndex(where: {
            $0.serverId == key.serverId && $0.userId == key.userId
        }) {
            payload.credentials[index] = credential
        } else {
            payload.credentials.append(credential)
        }

        if payload.active == nil {
            payload.active = key
        }

        try storePayload(payload)
    }

    /// 标记某条凭据为「上次使用」。
    ///
    /// - Parameters:
    ///   - serverId: 服务器 id。
    ///   - userId: 用户 id。
    /// - Throws: ``SessionStoreError/sessionNotFound(serverId:userId:)``（凭据不存在时）。
    public func setActive(serverId: String, userId: String) throws {
        var payload = try loadPayload()
        let key = CredentialKey(serverId: serverId, userId: userId)
        guard payload.credentials.contains(where: {
            $0.serverId == key.serverId && $0.userId == key.userId
        }) else {
            throw SessionStoreError.sessionNotFound(serverId: serverId, userId: userId)
        }
        payload.active = key
        try storePayload(payload)
    }

    // MARK: 读取

    /// 读出全部凭据（按写入顺序，旧的在前面）。
    ///
    /// - Returns: 凭据数组；没有任何记录时为空数组。
    /// - Throws: ``SessionStoreError``。
    public func loadAll() throws -> [StoredCredential] {
        try loadPayload().credentials
    }

    /// 精确读取某条凭据。
    ///
    /// - Parameters:
    ///   - serverId: 服务器 id。
    ///   - userId: 用户 id。
    /// - Returns: 凭据；不存在时为 `nil`。
    /// - Throws: ``SessionStoreError``。
    public func credential(serverId: String, userId: String) throws -> StoredCredential? {
        try loadPayload().credentials.first {
            $0.serverId == serverId && $0.userId == userId
        }
    }

    /// 上次使用的凭据，供启动时重新登录。
    ///
    /// 回退规则（**明确定义并被测试覆盖**）：
    /// 1. 有 active 标记且对应凭据还在 → 返回它。
    /// 2. active 标记指向的凭据已被删除（或标记丢失）→ 返回「最新」的那条：
    ///    `lastSignedInAt` 较晚者优先；相同或都为 `nil` 时，取写入顺序靠后的那个。
    /// 3. 一条凭据都没有 → `nil`。
    ///
    /// 该回退**只读不写**：调用方拿到结果后要不要重新 ``setActive(serverId:userId:)``
    /// 由它自己决定，避免「读操作偷偷改数据」这种难排查的行为。
    ///
    /// - Returns: 凭据或 `nil`。
    /// - Throws: ``SessionStoreError``。
    public func active() throws -> StoredCredential? {
        let payload = try loadPayload()
        guard !payload.credentials.isEmpty else { return nil }

        if let key = payload.active,
           let credential = payload.credentials.first(where: {
               $0.serverId == key.serverId && $0.userId == key.userId
           }) {
            return credential
        }
        return Self.mostRecent(in: payload.credentials)
    }

    // MARK: 删除

    /// 删除某个服务器下的凭据（幂等）。
    ///
    /// 若删掉的正是 active，会把 active 改指向剩余的「最新」凭据；没有剩余则清空标记。
    ///
    /// - Parameter serverId: 服务器 id。
    /// - Throws: ``SessionStoreError``。
    public func remove(serverId: String) throws {
        var payload = try loadPayload()
        payload.credentials.removeAll { $0.serverId == serverId }
        if payload.active?.serverId == serverId {
            payload.active = Self.mostRecent(in: payload.credentials).map {
                CredentialKey(serverId: $0.serverId, userId: $0.userId)
            }
        }
        try storePayload(payload)
    }

    /// 用户主动登出时调用：删掉该服务器的凭据，但**不动服务器列表**。
    ///
    /// 服务器地址/名称保存在 ``ServerRegistry`` 里，因此登录页仍然能列出这台服务器，
    /// 用户只需重新输密码，不用重新填地址。
    ///
    /// - Parameter serverId: 服务器 id。
    /// - Throws: ``SessionStoreError``。
    public func markLoggedOut(serverId: String) throws {
        try remove(serverId: serverId)
    }

    /// 清空全部凭据（注销所有服务器 / 重置应用）。
    ///
    /// - Throws: ``SessionStoreError``。
    public func removeAll() throws {
        try secureStore.deleteAll(service: service)
    }

    /// 清掉旧版本（存 token 时代）遗留的文件。
    ///
    /// 升级到「存密码」之后，旧文件里的 token 已无用武之地；留着只会让人误以为
    /// 登录态还在。登录成功或明确登出时顺手删除，失败也无所谓（幂等，下次再删）。
    public func removeLegacyTokenFile() {
        try? secureStore.delete(account: Self.legacySessionsAccount, service: service)
    }

    // MARK: 内部

    /// 读出 blob；不存在或为空时返回空载荷。
    private func loadPayload() throws -> CredentialPayload {
        guard let data = try secureStore.load(account: Self.credentialsAccount, service: service) else {
            return .empty
        }
        guard !data.isEmpty else { return .empty }

        do {
            let payload = try SessionJSON.makeDecoder().decode(CredentialPayload.self, from: data)
            guard payload.schemaVersion <= CredentialPayload.currentSchemaVersion else {
                throw SessionStoreError.decoding(
                    "不支持的凭据存储版本：\(payload.schemaVersion)"
                )
            }
            return payload
        } catch let error as SessionStoreError {
            throw error
        } catch {
            throw SessionStoreError.decoding(String(describing: error))
        }
    }

    /// 写回 blob。
    private func storePayload(_ payload: CredentialPayload) throws {
        let data: Data
        do {
            data = try SessionJSON.makeEncoder().encode(payload)
        } catch {
            throw SessionStoreError.encoding(String(describing: error))
        }
        try secureStore.save(data, account: Self.credentialsAccount, service: service)
    }

    /// 按「`lastSignedInAt` 晚者优先，同序取后者」挑出最新凭据。
    private static func mostRecent(in credentials: [StoredCredential]) -> StoredCredential? {
        credentials.enumerated().max { lhs, rhs in
            let left = lhs.element.lastSignedInAt ?? .distantPast
            let right = rhs.element.lastSignedInAt ?? .distantPast
            if left == right {
                return lhs.offset < rhs.offset
            }
            return left < right
        }?.element
    }
}