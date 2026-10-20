import Foundation
import PrismCore

/// 把 ``EmbyEndpoint`` + ``ClientIdentity`` + token 组装成 `URLRequest`。
///
/// 拆成独立类型而不是塞进 ``EmbyClient``，是因为 URL 拼接与头构造是纯函数，
/// 可以在不启动 `URLSession` 的情况下逐条单测（基址 4 种形态、百分号编码等）。
///
/// ## 基址拼接规则
///
/// 用户可能填这些地址，都要拼对：
///
/// | 用户填写 | `/Users/Me` 的实际请求 URL |
/// |---|---|
/// | `http://host:8096` | `http://host:8096/Users/Me` |
/// | `http://host:8096/` | `http://host:8096/Users/Me` |
/// | `http://host:8096/emby` | `http://host:8096/emby/Users/Me` |
/// | `https://domain/emby` | `https://domain/emby/Users/Me` |
///
/// 做法：取基址的 path，**去掉尾部的 `/`**，再接上端点的 `path`（保证以 `/` 开头）。
/// 这样既不会出现 `//`，也不会把 `/emby` 反代前缀丢掉。
/// 基址自带的 query / fragment 会被丢弃（服务器地址不该带它们）。
public struct RequestBuilder: Sendable {
    /// 端点未声明 `timeout` 时的默认超时（秒）。
    public static let defaultTimeout: TimeInterval = 30

    /// 请求体未声明 `contentType` 时使用的类型。
    public static let defaultContentType = "application/json"

    /// `Accept` 头的值。固定 JSON，避免服务器按 `Accept` 返回 XML。
    public static let accept = "application/json"

    /// 服务器基地址。
    public let baseURL: URL

    /// 客户端身份（用于构造鉴权头）。
    public let identity: ClientIdentity

    /// 以基址与身份创建。
    ///
    /// - Parameters:
    ///   - baseURL: 服务器基地址，可带反代前缀（如 `https://domain/emby`）。
    ///   - identity: 客户端身份。
    public init(baseURL: URL, identity: ClientIdentity) {
        self.baseURL = baseURL
        self.identity = identity
    }

    /// 计算端点的完整 URL。
    ///
    /// - Parameter endpoint: 端点。
    /// - Returns: 拼接好 path 与 query 的绝对 URL。
    /// - Throws: ``PrismCore/EmbyError/invalidURL``：基址缺 scheme/host，或拼接结果非法。
    public func url(for endpoint: EmbyEndpoint) throws -> URL {
        try Self.joinedURL(baseURL: baseURL, path: endpoint.path, query: endpoint.query)
    }

    /// 构造请求。
    ///
    /// - Parameters:
    ///   - endpoint: 端点。
    ///   - token: 访问令牌；`nil` 时不发 `X-Emby-Token`，鉴权头也省略 `Token=`。
    ///   - userId: 当前用户 id；`nil` 时鉴权头省略 `UserId=`。
    /// - Returns: 可直接交给 `URLSession` 的请求。
    /// - Throws: ``PrismCore/EmbyError/invalidURL``。
    public func build(_ endpoint: EmbyEndpoint, token: String?, userId: String?) throws -> URLRequest {
        let url = try url(for: endpoint)
        var request = URLRequest(
            url: url,
            cachePolicy: endpoint.cachePolicy,
            timeoutInterval: endpoint.timeout ?? Self.defaultTimeout
        )
        request.httpMethod = endpoint.method.rawValue
        request.setValue(Self.accept, forHTTPHeaderField: "Accept")

        // 鉴权头**总是**发送：登录端点也要求它存在（只是没有 Token/UserId）。
        let header = AuthHeader(identity: identity)
        request.setValue(
            header.headerValue(userId: userId, token: token),
            forHTTPHeaderField: AuthHeader.headerName
        )
        if let token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: AuthHeader.tokenHeaderName)
        }

        if let body = endpoint.body {
            request.httpBody = body
            request.setValue(
                endpoint.contentType ?? Self.defaultContentType,
                forHTTPHeaderField: "Content-Type"
            )
        }
        return request
    }

    /// 基址 + path + query 的纯函数实现。
    ///
    /// - Parameters:
    ///   - baseURL: 服务器基地址。
    ///   - path: 以 `/` 开头的端点路径（不以 `/` 开头时自动补上）。
    ///   - query: 查询参数；按 key 字典序输出，值用 `%20` 而非 `+` 编码。
    /// - Returns: 绝对 URL。
    /// - Throws: ``PrismCore/EmbyError/invalidURL``。
    public static func joinedURL(baseURL: URL, path: String, query: [String: String]) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme != nil,
              components.host != nil
        else {
            throw EmbyError.invalidURL
        }

        // 1. 基址 path 去掉尾部斜杠：`/emby/` → `/emby`，`/` → ``。
        var basePath = components.path
        while basePath.hasSuffix("/") {
            basePath.removeLast()
        }

        // 2. 端点 path 保证以 `/` 开头，避免拼出 `//`。
        let suffix = path.hasPrefix("/") ? path : "/" + path
        components.path = basePath + suffix

        // 3. query 自己编码：与 `EmbyEndpoint.resolvedPath()` 完全一致的规则
        //    （空格 → `%20`，并额外转义 `+ & = ? # [ ]`）。
        components.fragment = nil
        if query.isEmpty {
            components.percentEncodedQuery = nil
        } else {
            let pairs = query
                .sorted { $0.key < $1.key }
                .map { "\($0.key.percentEncodedQueryValue)=\($0.value.percentEncodedQueryValue)" }
            components.percentEncodedQuery = pairs.joined(separator: "&")
        }

        guard let url = components.url else { throw EmbyError.invalidURL }
        return url
    }
}
