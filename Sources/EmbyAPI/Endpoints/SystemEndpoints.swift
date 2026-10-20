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
/// 官方文档：<https://dev.emby.media/reference/RestAPI/UserService/getUsersMe.html>
///
/// 返回 ``PrismCore/EmbyUser``。典型用法：App 启动时用本地保存的 token 打一次，
/// 401 说明 token 已被吊销，应跳回登录页。
public struct CurrentUserEndpoint: EmbyEndpoint {
    /// 无参数。
    public init() {}

    /// `/Users/Me`。
    public var path: String { "/Users/Me" }
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
