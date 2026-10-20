import Foundation
import PrismCore

/// 多服务器列表：地址、名称、上次连接时间、上次激活的服务器。
///
/// **为什么和 token 分开存**
///
/// 这些信息**不含敏感内容**：服务器地址、展示名、是不是 Demo 服务器。
/// 它们放 `UserDefaults`（独立 suite，便于测试注入）就够了，不需要进 Keychain；
/// 而 token 只能进 Keychain（`docs/research/macos-engineering.md` §5.3）。
/// 分开的好处：
///
/// - **换地址不用重登**：同一服务器的局域网地址 / 公网地址可以随时改，token 不受影响。
/// - **清 token 不丢服务器**：401 之后只清 ``SessionStore`` 里的会话，用户重新输密码即可，
///   地址还在，登录页可以直接预填。
/// - **Keychain 条目保持最少**：只有一条会话 blob，不会因为服务器数量增长而变多。
///
/// 存储形态是一段 JSON（`[ServerConnection]`）：
/// ``ServerConnection`` 本身就是 `Codable`，直接复用可以避免再定义一套 DTO；
/// 用 `Data` 而不是把每个字段摊成多个 key，是为了增删字段时不需要迁移逻辑。
///
/// 测试注入：构造时传入独立 suite 的 `UserDefaults`，例如
/// `UserDefaults(suiteName: "test.prism.\(UUID().uuidString)")`，测完
/// `removePersistentDomain(forName:)` 清理。**不要**用 `.standard`，
/// 否则测试会污染真实偏好设置。
public actor ServerRegistry {
    /// 服务器列表在 `UserDefaults` 里的键名。
    public static let defaultServersKey = "app.prism.servers.v1"
    /// 「上次激活的服务器」在 `UserDefaults` 里的键名。
    public static let defaultActiveServerKey = "app.prism.servers.lastActive"

    private let defaults: UserDefaults
    private let serversKey: String
    private let activeServerKey: String

    /// 创建实例。
    ///
    /// - Parameters:
    ///   - defaults: 持久化容器，默认 `.standard`；测试必须传独立 suite。
    ///   - serversKey: 服务器列表键名。
    ///   - activeServerKey: 上次激活服务器键名。
    public init(
        defaults: UserDefaults = .standard,
        serversKey: String = ServerRegistry.defaultServersKey,
        activeServerKey: String = ServerRegistry.defaultActiveServerKey
    ) {
        self.defaults = defaults
        self.serversKey = serversKey
        self.activeServerKey = activeServerKey
    }

    // MARK: 查询

    /// 全部服务器，**最近使用的排在最前**。
    ///
    /// 排序规则：`lastConnectedAt` 降序；没有连接时间（从未连上 / 手填未验证）的排最后；
    /// 时间相同时按展示名、再按 id 排，保证顺序稳定（同样的数据永远给同样的结果，
    /// UI 列表不会无缘无故抖动）。
    ///
    /// - Returns: 服务器数组；没有任何记录时为空数组。
    public func servers() -> [ServerConnection] {
        readAll().sorted { lhs, rhs in
            let left = lhs.lastConnectedAt ?? .distantPast
            let right = rhs.lastConnectedAt ?? .distantPast
            if left != right { return left > right }
            if lhs.name != rhs.name {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    /// 按 id 查服务器。
    ///
    /// - Parameter id: 服务器 id。
    /// - Returns: 服务器；不存在时为 `nil`。
    public func server(id: String) -> ServerConnection? {
        readAll().first { $0.id == id }
    }

    /// 上次激活的服务器 id（用于登录页预选，**不是**登录态本身）。
    ///
    /// 真正的「当前登录的是哪个会话」由 ``SessionStore/active()`` 回答；
    /// 这里只是 UI 提示：401 之后会话没了，这个值仍然保留，用户点「重新登录」
    /// 就能直接落到上次那台服务器。
    public var lastActiveServerId: String? {
        defaults.string(forKey: activeServerKey)
    }

    // MARK: 修改

    /// 新增或更新一台服务器（按 `id` 判重，重复则原位替换）。
    ///
    /// - Parameter connection: 服务器连接信息。
    public func upsert(_ connection: ServerConnection) {
        var all = readAll()
        if let index = all.firstIndex(where: { $0.id == connection.id }) {
            all[index] = connection
        } else {
            all.append(connection)
        }
        write(all)
    }

    /// 删除一台服务器（幂等）。若它正好是「上次激活」，一并清掉该标记。
    ///
    /// - Parameter id: 服务器 id。
    public func remove(id: String) {
        let all = readAll()
        let remaining = all.filter { $0.id != id }
        guard remaining.count != all.count else { return }
        write(remaining)
        if lastActiveServerId == id {
            setLastActiveServerId(nil)
        }
    }

    /// 清空服务器列表（同时清掉「上次激活」标记）。
    public func removeAll() {
        defaults.removeObject(forKey: serversKey)
        defaults.removeObject(forKey: activeServerKey)
    }

    /// 记录一次成功使用：更新 `lastConnectedAt`，并把它设为「上次激活」。
    ///
    /// - Parameters:
    ///   - id: 服务器 id。
    ///   - date: 使用时间，默认当前时间（测试可注入固定值）。
    /// - Returns: 找到并更新返回 `true`；列表里没有这台服务器返回 `false`
    ///   （调用方应先用 ``upsert(_:)`` 登记）。
    @discardableResult
    public func markUsed(id: String, at date: Date = .now) -> Bool {
        var all = readAll()
        guard let index = all.firstIndex(where: { $0.id == id }) else { return false }
        all[index].lastConnectedAt = date
        write(all)
        setLastActiveServerId(id)
        return true
    }

    /// 设置「上次激活的服务器」；传 `nil` 表示清除。
    ///
    /// - Parameter id: 服务器 id。
    public func setLastActiveServerId(_ id: String?) {
        if let id, !id.isEmpty {
            defaults.set(id, forKey: activeServerKey)
        } else {
            defaults.removeObject(forKey: activeServerKey)
        }
    }

    // MARK: 内部

    /// 读出全部服务器；数据损坏时返回空数组而不是抛错。
    ///
    /// 这里刻意**不抛错**：服务器列表是「锦上添花」的信息，读坏了应该退化成
    /// 「让用户重新添加服务器」，而不是让整个启动流程失败。
    private func readAll() -> [ServerConnection] {
        guard let data = defaults.data(forKey: serversKey), !data.isEmpty else { return [] }
        guard let decoded = try? JSONDecoder().decode([ServerConnection].self, from: data) else {
            return []
        }
        return decoded
    }

    /// 写回全部服务器。
    private func write(_ connections: [ServerConnection]) {
        guard let data = try? JSONEncoder().encode(connections) else { return }
        defaults.set(data, forKey: serversKey)
    }
}
