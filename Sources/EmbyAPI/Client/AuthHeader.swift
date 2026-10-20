import Foundation

/// Emby 鉴权头的构造器。
///
/// Emby 要求请求带上形如下面这个值（字段来源已核实，见 `docs/research/verified-facts.md` A1）：
///
/// ```text
/// Emby UserId="<guid>", Client="<client>", Device="<device>", DeviceId="<id>", Version="<ver>", Token="<token>"
/// ```
///
/// 规则：
/// - 头名可以是 `Authorization` 或 `X-Emby-Authorization`，二者**等价**。
///   Prism 默认用后者（``headerName``），这样用户把 Emby 挂在反向代理上
///   （`https://domain/emby`）且代理自己用 `Authorization: Basic ...` 时不会互相覆盖。
/// - 未登录（没有 token / userId）时**省略** `UserId=` 与 `Token=`，其余字段保留 ——
///   登录端点 `POST /Users/AuthenticateByName` 明确要求这个头存在。
/// - 令牌同时用 `X-Emby-Token` 头发送（``tokenHeaderName``）：官方文档写明后续请求
///   「should be included in all subsequent Http requests using the header X-Emby-Token」，
///   而 `Token="..."` 字段与它是两条独立的读取路径，两个都发最大化兼容。
/// - 分隔符是**逗号 + 空格**，整个值**不要**加外层引号。
///
/// 来源：
/// - <https://dev.emby.media/doc/restapi/User-Authentication.html>
/// - <https://dev.emby.media/reference/RestAPI/UserService/postUsersAuthenticatebyname.html>
public struct AuthHeader: Sendable, Hashable {
    /// Prism 默认使用的鉴权头名。
    public static let headerName = "X-Emby-Authorization"

    /// 与 ``headerName`` 等价的另一种头名（官方明示二者等价）。
    public static let alternateHeaderName = "Authorization"

    /// 携带访问令牌的头名。
    public static let tokenHeaderName = "X-Emby-Token"

    /// 客户端名（`Client=`）。
    public let client: String

    /// 设备名（`Device=`）。
    public let device: String

    /// 设备唯一标识（`DeviceId=`）。
    public let deviceId: String

    /// 客户端版本（`Version=`）。
    public let version: String

    /// 以客户端身份创建。
    ///
    /// - Parameter identity: ``ClientIdentity``。
    public init(identity: ClientIdentity) {
        self.init(
            client: identity.appName,
            device: identity.deviceName,
            deviceId: identity.deviceId,
            version: identity.appVersion
        )
    }

    /// 逐字段初始化（便于测试与特殊场景）。
    ///
    /// - Parameters:
    ///   - client: 客户端名。
    ///   - device: 设备名。
    ///   - deviceId: 设备唯一标识。
    ///   - version: 客户端版本。
    public init(client: String, device: String, deviceId: String, version: String) {
        self.client = client
        self.device = device
        self.deviceId = deviceId
        self.version = version
    }

    /// 生成鉴权头的值。
    ///
    /// - Parameters:
    ///   - userId: 当前登录用户 id；`nil` 或空串时省略 `UserId=`。
    ///   - token: 访问令牌；`nil` 或空串时省略 `Token=`。
    /// - Returns: 形如 `Emby UserId="u1", Client="Prism", ...` 的字符串。
    ///
    /// - Important: 首词 `Emby` 与后续字段之间是**空格**，字段之间才是「逗号 + 空格」。
    ///   把所有部分一起 `joined(separator: ", ")` 会得到 `Emby, UserId="..."` —— 多一个逗号，
    ///   服务端会把 scheme 解析成 `Emby,`。`docs/research/emby-api.md` §2.1 的示例代码
    ///   就有这个问题，这里按官方 schema 原文修正。
    public func headerValue(userId: String?, token: String?) -> String {
        var fields: [String] = []
        if let userId, !userId.isEmpty {
            fields.append("UserId=\"\(Self.sanitized(userId))\"")
        }
        fields.append("Client=\"\(Self.sanitized(client))\"")
        fields.append("Device=\"\(Self.sanitized(device))\"")
        fields.append("DeviceId=\"\(Self.sanitized(deviceId))\"")
        fields.append("Version=\"\(Self.sanitized(version))\"")
        if let token, !token.isEmpty {
            fields.append("Token=\"\(Self.sanitized(token))\"")
        }
        return "Emby " + fields.joined(separator: ", ")
    }

    /// 去掉会破坏 `Key="value"` 结构的字符。
    ///
    /// 设备名来自用户（可能含引号，例如 `Bob 的 "MacBook"`），若不处理会把整个头
    /// 拆成错误的键值对。这里直接移除反斜杠与双引号、把换行折成空格：
    /// Emby 的服务端解析器没有公开的反转义规则（【待验证】），
    /// 因此选择「丢弃」而不是「转义」，保证头永远合法。
    ///
    /// - Note: 中文设备名（如 `fuunylmz的Mac Mini`）**不转码**。本机实测
    ///   `URLSession` 会把非 ASCII 字符按 UTF-8 原样放进头值（见 `.spike/header` 探针），
    ///   而真实 Emby（ASP.NET Core）如何解码非 ASCII 头值尚未验证 —— 【待验证】。
    ///   验证方法：在设备名含中文的 Mac 上连真实服务器，看 Dashboard → Devices 里的名字。
    ///
    /// - Parameter raw: 原始字段值。
    /// - Returns: 可安全嵌入引号内的值。
    private static func sanitized(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
