import Foundation
import PrismCore

// MARK: - 公开信息

/// `GET /System/Info/Public` —— 登录前的服务器探测。
///
/// 官方文档：<https://dev.emby.media/reference/RestAPI/SystemService/getSystemInfoPublic.html>
///
/// 用途：手动填地址后第一枪。200 即代表「这是一台 Emby/Jellyfin 服务器」，
/// 同时拿到 `ServerName` / `Version` 做展示、`Id` 做多服务器主键。
///
/// **不需要 token**（`requiresAuth = false`），返回 ``PrismCore/PublicServerInfo``。
///
/// ```swift
/// let info: PublicServerInfo = try await client.send(PublicSystemInfoEndpoint())
/// ```
public struct PublicSystemInfoEndpoint: EmbyEndpoint {
    /// 无参数。
    public init() {}

    /// `/System/Info/Public`。
    public var path: String { "/System/Info/Public" }

    /// 不需要鉴权。
    public var requiresAuth: Bool { false }

    /// 连接校验要快，给一个较短超时（10 秒）。
    public var timeout: TimeInterval? { 10 }
}

// MARK: - 当前用户

/// `GET /Users/Me` —— 取当前 token 对应的用户，用于恢复会话。
///
/// 返回 ``PrismCore/EmbyUser``。典型用法：App 启动时用本地保存的 token 打一次，
/// 401 说明 token 已被吊销，应跳回登录页。
///
/// ## ⚠️ Emby 侧存在性存疑（本项目已核查，务必读）
///
/// - ◐ **Jellyfin 确认有**：`/Users/Me` 在 Jellyfin stable OpenAPI 里存在
///   （<https://api.jellyfin.org/openapi/jellyfin-openapi-stable.json>）。
/// - ○ **Emby 侧未确认**：Emby 的 Reference 站点**找不到**该端点的页面
///   （`UserService/getUsersMe.html` 等多个候选名均 404），
///   4.1.1.0 版 OpenAPI 快照（<https://swagger.emby.media/openapi.json>）的
///   `/Users/*` 路径列表里也没有它（只有 `/Users/{Id}`）。
/// - ◐ 社区反馈：有第三方集成报告 Emby 对 `/Users/Me` 返回 500，并指出
///   Emby 只有 `/Users/{guid}`
///   （<https://doublepost.link/guild/1254564006123802805/thread/1466887133573677086>）。
///
/// **结论与处置**：端点按工单与架构契约保留（Jellyfin 可用、Emby 新版本可能已支持），
/// 但恢复会话时**必须有回退**：本地已存 `userId` 时改用 ``UserByIdEndpoint``
/// （`GET /Users/{Id}`，官方 Reference 与 OpenAPI 均有）。
/// 验证方法：对 Emby 4.8 / 4.9 各 `curl -i -H "X-Emby-Token: …" /Users/Me`，
/// 记录状态码与 body。
public struct CurrentUserEndpoint: EmbyEndpoint {
    /// 无参数。
    public init() {}

    /// `/Users/Me`。
    public var path: String { "/Users/Me" }
}

/// `GET /Users/{Id}` —— 按 id 取用户（``CurrentUserEndpoint`` 的回退方案）。
///
/// 官方文档：<https://dev.emby.media/reference/RestAPI/UserService/getUsersById.html>
/// （已核实页面存在，返回 `UserDto`）。
///
/// Emby 侧该端点确定存在；本地保存了 `userId` 时优先用它恢复会话，比 `/Users/Me` 稳妥。
public struct UserByIdEndpoint: EmbyEndpoint {
    /// 用户 id。
    public let userId: String

    /// 以用户 id 创建。
    ///
    /// - Parameter userId: 用户 id。
    public init(userId: String) {
        self.userId = userId
    }

    /// `/Users/{userId}`。
    public var path: String { "/Users/\(userId)" }
}

// MARK: - 登出

/// `POST /Sessions/Logout` —— 登出并**吊销**当前 token。
///
/// 官方文档：<https://dev.emby.media/doc/restapi/User-Authentication.html>
/// （“Logout … will revoke the access token”）。
///
/// - Important: 用户只是关掉 App **不要**调这个接口，直接保存 token 下次复用
///   （官方明确建议）。只在用户主动点「登出」时调用。
///
/// 无返回体：用 `client.send(endpoint)` 的无泛型重载。
public struct LogoutEndpoint: EmbyEndpoint {
    /// 无参数。
    public init() {}

    /// `/Sessions/Logout`。
    public var path: String { "/Sessions/Logout" }

    /// 必须带 token 才能吊销。
    public var method: HTTPMethod { .post }
}
