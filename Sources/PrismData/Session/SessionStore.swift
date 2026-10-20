import Foundation
import PrismCore

// MARK: - 存储格式

/// 会话在 Keychain 里的完整载荷（一个 JSON blob）。
///
/// **为什么把「所有会话 + active 标记」放进一条 item，而不是每个字段一条 item**
///
/// 1. **原子性**：Keychain 没有事务。若按「一个服务器一条 item」存，`save` + `setActive`
///    是两次独立的 `SecItemAdd`/`SecItemUpdate`，中间崩溃就会留下「令牌存了但 active 没更新」
///    或「新服务器写了一半」的半状态。一个 blob 只有一次写入，天然原子。
/// 2. **读取成本**：启动时恢复登录只需要**一次** `SecItemCopyMatching`。按条存就得先用
///    `kSecMatchLimitAll` 枚举出所有账号、再逐条取数据，N 个服务器就是 N+1 次 IPC。
///    启动路径上的每一次钥匙串往返都是可见的冷启动开销。
/// 3. **元数据不入属性**：`activeSessionId`、schema 版本这类结构化信息如果塞进
///    `kSecAttrGeneric`/`kSecAttrLabel`，会变成不可版本化的属性拼装；放进 JSON 里改起来
///    只是改结构体，不需要迁移钥匙串属性。
/// 4. **可降级**：``SecureStoring`` 把「怎么存」隔离掉了。真到了「必须单条独立吊销」
///    那天，换一个实现即可，`SessionStore` 的公共 API 不用动。
///
/// **代价（已权衡）**：所有服务器的 token 共享一条 item 的 ACL；单条 item 损坏会一起丢。
/// 前者的实际影响是「解锁一次钥匙串即可读全部」，正是我们想要的；后者靠
/// ``SessionStore`` 的「解码失败 → 抛 `SessionStoreError.decoding`」让上层引导重新登录，
/// 而不是静默返回空数组假装未登录（那会掩盖 bug）。
///
/// **不存明文密码**：``AuthSession`` 只含 `AccessToken`，登录密码只在登录请求期间存在于
/// 内存，既不进 Keychain 也不进 `UserDefaults`。
///
/// 字段名用 Swift 习惯的 lowerCamelCase 而非 Emby 的 PascalCase：这个 blob 是**本机私有
/// 格式**，不需要和服务器 DTO 保持一致，独立命名可以避免以后跟着 Emby 改字段名而牵连迁移。
struct SessionPayload: Codable, Sendable, Equatable {
    /// 当前格式版本。读到更高版本视为不兼容（见 ``SessionStore``）。
    static let currentSchemaVersion = 1

    /// 格式版本。
    var schemaVersion: Int
    /// 全部会话，**保持写入顺序**（新保存的追加在末尾）。
    var sessions: [AuthSession]
    /// 上次激活的会话标识；`nil` 表示没标记过。
    var active: SessionKey?

    /// 空载荷。
    static var empty: SessionPayload {
        SessionPayload(schemaVersion: currentSchemaVersion, sessions: [], active: nil)
    }
}

/// 会话标识：`serverId` + `userId` 的组合。
///
/// 不用 ``AuthSession/id``（`"\(serverId):\(userId)"` 字符串）作为持久化 key：
/// 一旦某个 serverId 或 userId 里出现冒号，拼接就会撞 key。分开存字段没有这个问题。
struct SessionKey: Codable, Sendable, Hashable {
    /// 服务器 id。
    let serverId: String
    /// 用户 id。
    let userId: String
}

// MARK: - SessionStore

/// 登录态持久化：把 ``AuthSession`` 放进 Keychain，支持多服务器、多用户共存。
///
/// 典型用法：
///
/// ```swift
/// let store = SessionStore(secureStore: KeychainSecureStore())
/// try await store.save(session)                       // 登录成功后
/// let active = try await store.active()               // 启动时免登录恢复
/// try await store.setActive(serverId: s, userId: u)   // 切换服务器
/// try await store.markLoggedOut(serverId: s)          // 收到 401
/// ```
///
/// 设计要点：
/// - **只有 token 进 Keychain**；服务器地址、名称、图标等非敏感信息归
///   ``ServerRegistry`` 管（`UserDefaults`），两者刻意分开：换地址不该重登，
///   清 token 也不该丢服务器列表。
/// - 存取是**一个 JSON blob**，理由见 ``SessionPayload``。
/// - `actor`：所有调用串行化，避免「读-改-写」blob 时的竞态（例如同时登录两台服务器）。
public actor SessionStore {
    /// 默认的 Keychain service 名，与 `docs/research/macos-engineering.md` §5.3 一致。
    public static let defaultService = "app.prism.Prism"

    /// 承载 blob 的 Keychain account 名。
    ///
    /// 只有一条 item，所以是个固定值而不是 serverId。带 `v1` 后缀是为了将来换存储格式时
    /// 能并存新旧两份数据（先读新、读不到再读旧，迁移完删旧），不必原地改格式。
    static let sessionsAccount = "sessions.v1"

    /// 底层安全存储。
    private let secureStore: any SecureStoring
    /// Keychain service 名。
    private let service: String

    /// 创建实例。
    ///
    /// - Parameters:
    ///   - secureStore: 安全存储实现。生产环境用 ``KeychainSecureStore``，
    ///     测试必须用 ``InMemorySecureStore``（见 ``SecureStoring`` 的说明）。
    ///   - service: Keychain service 名，默认 ``defaultService``。
    public init(secureStore: any SecureStoring, service: String = SessionStore.defaultService) {
        self.secureStore = secureStore
        self.service = service
    }

    // MARK: 写入

    /// 保存（或覆盖）一个会话。
    ///
    /// 同一 `serverId` + `userId` 视为同一会话，重复保存会原位替换、不改变顺序。
    /// 若当前还没有 active 标记，新会话会被自动设为 active——这样「刚登录完就重启」
    /// 也能免登录恢复，不需要调用方额外记得调 ``setActive(serverId:userId:)``。
    ///
    /// - Parameter session: 待保存的会话。
    /// - Throws: ``SessionStoreError``。
    public func save(_ session: AuthSession) throws {
        var payload = try loadPayload()

        let key = SessionKey(serverId: session.serverId, userId: session.userId)
        if let index = payload.sessions.firstIndex(where: {
            $0.serverId == key.serverId && $0.userId == key.userId
        }) {
            payload.sessions[index] = session
        } else {
            payload.sessions.append(session)
        }

        if payload.active == nil {
            payload.active = key
        }

        try storePayload(payload)
    }

    /// 标记某个会话为「上次使用」。
    ///
    /// - Parameters:
    ///   - serverId: 服务器 id。
    ///   - userId: 用户 id。
    /// - Throws: ``SessionStoreError/sessionNotFound(serverId:userId:)``（会话不存在时）。
    public func setActive(serverId: String, userId: String) throws {
        var payload = try loadPayload()
        let key = SessionKey(serverId: serverId, userId: userId)
        guard payload.sessions.contains(where: {
            $0.serverId == key.serverId && $0.userId == key.userId
        }) else {
            throw SessionStoreError.sessionNotFound(serverId: serverId, userId: userId)
        }
        payload.active = key
        try storePayload(payload)
    }

    // MARK: 读取

    /// 读出全部会话（按写入顺序，旧的在前面）。
    ///
    /// - Returns: 会话数组；没有任何记录时为空数组。
    /// - Throws: ``SessionStoreError``。
    public func loadAll() throws -> [AuthSession] {
        try loadPayload().sessions
    }

    /// 精确读取某个会话。
    ///
    /// - Parameters:
    ///   - serverId: 服务器 id。
    ///   - userId: 用户 id。
    /// - Returns: 会话；不存在时为 `nil`。
    /// - Throws: ``SessionStoreError``。
    public func session(serverId: String, userId: String) throws -> AuthSession? {
        try loadPayload().sessions.first {
            $0.serverId == serverId && $0.userId == userId
        }
    }

    /// 上次使用的会话，供启动时免登录恢复。
    ///
    /// 回退规则（**明确定义并被测试覆盖**）：
    /// 1. 有 active 标记且对应会话还在 → 返回它。
    /// 2. active 标记指向的会话已被删除（或标记丢失）→ 返回「最新」的会话：
    ///    `createdAt` 较晚者优先；`createdAt` 相同或都为 `nil` 时，取写入顺序靠后的那个。
    /// 3. 一条会话都没有 → `nil`。
    ///
    /// 该回退**只读不写**：调用方拿到结果后要不要重新 ``setActive(serverId:userId:)``
    /// 由它自己决定，避免「读操作偷偷改数据」这种难排查的行为。
    ///
    /// - Returns: 会话或 `nil`。
    /// - Throws: ``SessionStoreError``。
    public func active() throws -> AuthSession? {
        let payload = try loadPayload()
        guard !payload.sessions.isEmpty else { return nil }

        if let key = payload.active,
           let session = payload.sessions.first(where: {
               $0.serverId == key.serverId && $0.userId == key.userId
           }) {
            return session
        }
        return Self.mostRecent(in: payload.sessions)
    }

    // MARK: 删除

    /// 删除某个用户的会话（幂等）。
    ///
    /// 若删掉的正是 active，会把 active 改指向剩余的「最新」会话；没有剩余则清空标记。
    /// 这样「删除后 active() 返回什么」是可预期的，而不是随机。
    ///
    /// - Parameters:
    ///   - serverId: 服务器 id。
    ///   - userId: 用户 id。
    /// - Throws: ``SessionStoreError``。
    public func remove(serverId: String, userId: String) throws {
        var payload = try loadPayload()
        payload.sessions.removeAll {
            $0.serverId == serverId && $0.userId == userId
        }
        if payload.active?.serverId == serverId, payload.active?.userId == userId {
            payload.active = Self.mostRecent(in: payload.sessions).map {
                SessionKey(serverId: $0.serverId, userId: $0.userId)
            }
        }
        try storePayload(payload)
    }

    /// 删除某个服务器下的**全部**会话（含该服务器的所有用户）。
    ///
    /// 对应 `docs/ARCHITECTURE.md` §4 里 `SessionStore.remove(serverId:)` 的语义；
    /// 与 ``remove(serverId:userId:)`` 重载并存，参数标签不同，不会歧义。
    ///
    /// - Parameter serverId: 服务器 id。
    /// - Throws: ``SessionStoreError``。
    public func remove(serverId: String) throws {
        var payload = try loadPayload()
        payload.sessions.removeAll { $0.serverId == serverId }
        if payload.active?.serverId == serverId {
            payload.active = Self.mostRecent(in: payload.sessions).map {
                SessionKey(serverId: $0.serverId, userId: $0.userId)
            }
        }
        try storePayload(payload)
    }

    /// token 失效（HTTP 401）时调用：清掉该服务器的登录态，但**不动服务器列表**。
    ///
    /// 语义上等价于 ``remove(serverId:)``：删除该服务器下的所有 ``AuthSession``。
    /// 服务器地址/名称保存在 ``ServerRegistry`` 里，因此用户重新登录时只需输密码，
    /// 不用重新填地址。单独留一个方法名是为了让调用点读起来就是「登出」而不是「删数据」，
    /// 将来若要在登出时额外做点什么（例如记一条「会话过期」时间戳），改这里就够了。
    ///
    /// - Parameter serverId: 服务器 id。
    /// - Throws: ``SessionStoreError``。
    public func markLoggedOut(serverId: String) throws {
        try remove(serverId: serverId)
    }

    /// 清空全部会话（注销所有服务器 / 重置应用）。
    ///
    /// - Throws: ``SessionStoreError``。
    public func removeAll() throws {
        try secureStore.deleteAll(service: service)
    }

    // MARK: 内部

    /// 读出 blob；不存在或为空时返回空载荷。
    private func loadPayload() throws -> SessionPayload {
        guard let data = try secureStore.load(account: Self.sessionsAccount, service: service) else {
            return .empty
        }
        guard !data.isEmpty else { return .empty }

        do {
            let payload = try SessionJSON.makeDecoder().decode(SessionPayload.self, from: data)
            guard payload.schemaVersion <= SessionPayload.currentSchemaVersion else {
                throw SessionStoreError.decoding(
                    "不支持的会话存储版本：\(payload.schemaVersion)"
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
    private func storePayload(_ payload: SessionPayload) throws {
        let data: Data
        do {
            data = try SessionJSON.makeEncoder().encode(payload)
        } catch {
            throw SessionStoreError.encoding(String(describing: error))
        }
        try secureStore.save(data, account: Self.sessionsAccount, service: service)
    }

    /// 按「`createdAt` 晚者优先，同序取后者」挑出最新会话。
    private static func mostRecent(in sessions: [AuthSession]) -> AuthSession? {
        sessions.enumerated().max { lhs, rhs in
            let left = lhs.element.createdAt ?? .distantPast
            let right = rhs.element.createdAt ?? .distantPast
            if left == right {
                return lhs.offset < rhs.offset
            }
            return left < right
        }?.element
    }
}
