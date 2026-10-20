import Foundation
import PrismCore

/// `POST /Users/AuthenticateByName` —— 用户名 + 密码登录。
///
/// 官方文档：<https://dev.emby.media/reference/RestAPI/UserService/postUsersAuthenticatebyname.html>
///
/// ## 请求
///
/// ```json
/// { "Username": "alice", "Pw": "plaintext-password" }
/// ```
///
/// - Important: 密码字段名是 **`Pw`**，不是 `Password`（见 ``AuthenticateUserByName``）。
/// - Important: 密码是**明文**传输，必须走 HTTPS，否则凭据裸奔。
/// - Note: 该端点**不需要 token**（`requiresAuth = false`），但需要 `X-Emby-Authorization`
///   头里的 `Client` / `Device` / `DeviceId` / `Version`；该头由 `EmbyClient` 统一注入。
///
/// ## 响应
///
/// ``AuthenticationResult``（`User` / `SessionInfo` / `AccessToken` / `ServerId`）。
/// 业务层通常只取 ``AuthenticationResult/asSession`` 得到可持久化的
/// ``PrismCore/AuthSession``。
public struct AuthenticateEndpoint: EmbyEndpoint {
    /// 登录凭据。
    public let credentials: AuthenticateUserByName

    /// 以用户名与密码创建。
    ///
    /// - Parameters:
    ///   - username: 用户名。
    ///   - password: 明文密码。
    public init(username: String, password: String) {
        self.credentials = AuthenticateUserByName(username: username, password: password)
    }

    /// 以已构造的请求体创建。
    ///
    /// - Parameter credentials: 登录凭据。
    public init(credentials: AuthenticateUserByName) {
        self.credentials = credentials
    }

    /// `/Users/AuthenticateByName`。
    public var path: String { "/Users/AuthenticateByName" }

    /// `POST`。
    public var method: HTTPMethod { .post }

    /// 登录时还没有 token。
    public var requiresAuth: Bool { false }

    /// 请求体（PascalCase，`Pw` 字段）。
    public var body: Data? {
        try? EmbyJSON.encode(credentials)
    }

    /// JSON 请求体。
    public var contentType: String? { "application/json" }
}
