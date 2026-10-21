import Foundation
import PrismCore

// MARK: - 本地凭据

/// 保存在本机的登录凭据：服务器 + 用户名 + 密码。
///
/// ## 为什么存密码而不是 token
///
/// 早期版本保存的是 Emby 的 `AccessToken`。token 会在以下情况失效，而客户端无从预知：
/// 用户在服务器端「吊销设备」、改了密码、管理员踢人、服务器重装。
/// 一旦失效，用户就得重新登录——表现为「过一阵子又要输一遍」。
///
/// 改存密码后，每次启动都用它重新换取新 token：
/// - token 永远是最新的，不存在「过期后被迫重登」；
/// - 服务器端吊销旧 token 也不影响，下次启动自然拿到新的。
///
/// ## 安全边界（必须如实告知，不要粉饰）
///
/// - **这是本方案唯一的高风险点**。密码是主凭据：拿到它的人可以长期登录，
///   而 token 至少能被服务器单独吊销、且不会波及其它服务。
/// - 密码以**明文**存在 App 沙盒容器内的文件里
///   （`Application Support/Prism/Session/.../credentials.v1.json`）。
///   沙盒保证其它 App 读不到，但同一用户账号下运行的进程理论上可读。
/// - **绝不记录到日志**：``Redactor`` 会脱敏，本类型也不参与任何 `debugDescription`。
/// - 用户取消「记住我」时**不写这个文件**；退出登录时删除。
///
/// 如果将来要提升安全性，正确方向是接 Developer ID + provisioning profile 后用钥匙串
/// （`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`），而不是继续加本地加密——
/// 密钥同样要存在本机，只是把问题挪了一层。
public struct StoredCredential: Codable, Sendable, Hashable, Identifiable {
    /// 所属服务器 id。
    public let serverId: String
    /// 用户 id（登录后才知道，用于和服务器记录对齐）。
    public let userId: String
    /// 用户名（登录时输入）。
    public let username: String
    /// 密码（登录时输入，明文保存，见类型说明）。
    public let password: String
    /// 最近一次成功登录的时间，用于排序与排障。
    public let lastSignedInAt: Date?

    /// `Identifiable` 要求：同一服务器同一用户视为同一条凭据。
    public var id: String {
        "\(serverId):\(userId)"
    }

    /// 创建凭据。
    ///
    /// - Parameters:
    ///   - serverId: 服务器 id。
    ///   - userId: 用户 id。
    ///   - username: 用户名。
    ///   - password: 密码。
    ///   - lastSignedInAt: 最近成功登录时间。
    public init(
        serverId: String,
        userId: String,
        username: String,
        password: String,
        lastSignedInAt: Date? = nil
    ) {
        self.serverId = serverId
        self.userId = userId
        self.username = username
        self.password = password
        self.lastSignedInAt = lastSignedInAt
    }

    /// 是否包含可用于重新登录的信息。
    public var isUsable: Bool {
        !serverId.isEmpty && !username.isEmpty && !password.isEmpty
    }

    /// 用于日志的脱敏描述：**绝不输出密码**。
    public var redactedDescription: String {
        "StoredCredential(server: \(serverId), user: \(username), password: \(password.isEmpty ? "none" : "***"))"
    }

    private enum CodingKeys: String, CodingKey {
        case serverId
        case userId
        case username
        case password
        case lastSignedInAt
    }

    /// 宽松解码：字段缺失时退化为空串，不让一条坏记录毁掉整个文件。
    ///
    /// - Parameter decoder: 解码器。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.serverId = (try? container.decodeIfPresent(String.self, forKey: .serverId)) ?? ""
        self.userId = (try? container.decodeIfPresent(String.self, forKey: .userId)) ?? ""
        self.username = (try? container.decodeIfPresent(String.self, forKey: .username)) ?? ""
        self.password = (try? container.decodeIfPresent(String.self, forKey: .password)) ?? ""
        self.lastSignedInAt = container.decodeEmbyDateIfPresent(forKey: .lastSignedInAt)
    }

    /// 编码为持久化 JSON。
    ///
    /// - Parameter encoder: 编码器。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(serverId, forKey: .serverId)
        try container.encode(userId, forKey: .userId)
        try container.encode(username, forKey: .username)
        try container.encode(password, forKey: .password)
        try container.encodeEmbyDateIfPresent(lastSignedInAt, forKey: .lastSignedInAt)
    }
}
// MARK: - 登录输入

/// 一次登录输入的用户名与密码（只在登录流程内传递，不参与持久化）。
///
/// 单独建模而不是用元组：回调签名里有多个位置参数时，元组会退化成
/// `(String, String)`，调用点很容易把用户名和密码写反——那会静默变成
/// 「密码当用户名」，报错信息还看不出来。
public struct Credentials: Sendable, Hashable {
    /// 用户名。
    public let username: String
    /// 密码。
    public let password: String

    /// 创建凭据输入。
    ///
    /// - Parameters:
    ///   - username: 用户名。
    ///   - password: 密码。
    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    /// 用于日志的脱敏描述：**绝不输出密码**。
    public var redactedDescription: String {
        "Credentials(user: \(username), password: \(password.isEmpty ? "none" : "***"))"
    }
}
